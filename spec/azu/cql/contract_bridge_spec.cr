require "../../spec_helper"
require "http/client"
require "../../support/integration_helpers"
require "sqlite3"
require "../../../src/azu/cql"

module ContractBridgeSpec
  DB_FILE = File.tempname("azu_cql_contract_bridge", ".db")

  def self.build_schema : CQL::Schema
    File.delete?(DB_FILE)
    schema = Azu::CQL.schema(:contract_bridge, "sqlite3://#{DB_FILE}?busy_timeout=5000&foreign_keys=1", lazy: false) do
      table :people do
        primary :id, Int64
        column :name, String
        column :email, String
        column :bio, String, null: true
        column :created_at, Time, null: true
        column :updated_at, Time, null: true
      end
    end
    schema.build
    schema
  end

  SCHEMA = build_schema

  class Person
    include CQL::ActiveRecord::Model(Int64)
    include Azu::CQL::FromRequest
    db_context SCHEMA, :people

    property name : String
    property email : String
    property bio : String?
    property created_at : Time?
    property updated_at : Time?

    validate name, presence: true, size: 2..20
    validate email, presence: true, match: /@/

    def initialize(@name : String, @email : String)
    end
  end

  struct SignUp
    include Azu::Request

    getter name : String
    getter email : String
    getter bio : String?
    getter? admin : Bool = false # unknown to Person: ignored
    getter id : Int64 = 99       # never copied unless asked for
  end

  struct Renamed
    include Azu::Request

    getter full_name : String
    getter email : String
    getter bio : String?

    map_to Person, except: [:bio], rename: {name: :full_name}
  end

  # A plain (non-CQL) target whose constructor takes the server-set columns, to test the by-name guard.
  class Plain
    getter id : Int64?
    getter created_at : Time?
    getter name : String
    property role : String = "user"

    def initialize(@name : String, @id : Int64? = nil, @created_at : Time? = nil)
    end
  end

  struct Sneaky
    include Azu::Request

    getter name : String
    getter id : Int64? = 99
    getter created_at : Time? = Time.utc(2000, 1, 1)
    getter role : String = "admin"
  end

  struct Collides
    include Azu::Request

    getter full_name : String
    getter name : String = "other"
    getter email : String

    map_to Person, rename: {name: :full_name}
  end

  struct PersonResponse
    include Azu::Response
    include Azu::CQL::FromModel

    getter id : Int64?
    getter name : String
    getter bio : String?
    getter created_at : String?

    def initialize(@id : Int64?, @name : String, @bio : String?, @created_at : String?)
    end

    def render : String
      {id: id, name: name, bio: bio, created_at: created_at}.to_json
    end
  end

  struct Create
    include Azu::Endpoint(SignUp, PersonResponse)

    post "/people"

    def call : PersonResponse
      person = sign_up_contract.to_model(Person).valid_or_422!
      person.save!
      status 201
      PersonResponse.from(person)
    end
  end

  struct Saves
    include Azu::Endpoint(SignUp, PersonResponse)

    post "/people/save"

    def call : PersonResponse # relies on the middleware to turn the save error into a 422
      person = Person.from_request(sign_up_contract)
      person.save!
      PersonResponse.from(person)
    end
  end

  struct Failing
    include Azu::Endpoint(SignUp, PersonResponse)

    post "/people/boom"

    def call : PersonResponse
      Person.from_request(sign_up_contract).save!
      raise "boom after the insert"
    end
  end

  struct Server500
    include Azu::Endpoint(SignUp, PersonResponse)

    post "/people/500"

    def call : PersonResponse
      Person.from_request(sign_up_contract).save!
      status 500
      PersonResponse.from(Person.from_request(sign_up_contract))
    end
  end

  struct Concurrent
    include Azu::Endpoint(SignUp, PersonResponse)

    post "/people/concurrent"

    def call : PersonResponse
      sleep 5.milliseconds # other requests start their transactions meanwhile
      person = Person.from_request(sign_up_contract)
      person.save!
      raise "odd" if person.name[-1].to_i.odd?
      PersonResponse.from(person)
    end
  end

  def self.app : Azu::App
    app = Azu::App.new
    app.routes do
      endpoint Create
      endpoint Saves
      endpoint Failing
      endpoint Server500
      endpoint Concurrent
    end
    app
  end

  def self.serve(transaction : Bool = true, &)
    app = self.app
    handlers = [Azu::Handler::RequestId.new, Azu::Handler::Rescuer.new, Azu::CQL::Middleware.new(SCHEMA, transaction: transaction)] of HTTP::Handler
    server = app.server(handlers)
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield
    begin
      yield "http://#{address.address}:#{address.port}"
    ensure
      server.close
    end
  end

  def self.post(base : String, path : String, name : String, email : String = "#{name}@example.com") : HTTP::Client::Response
    HTTP::Client.post("#{base}#{path}", HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}, {name: name, email: email}.to_json)
  end

  def self.names : Array(String)
    SCHEMA.query.from(:people).select(:name).order(:name).all(String)
  end
end

include IntegrationHelpers

describe "contract <-> model bridge" do
  before_each { ContractBridgeSpec::SCHEMA.exec("DELETE FROM people") }

  describe "mapping" do
    it "builds a model from a request, ignoring unknown fields and never copying the id" do
      request = ContractBridgeSpec::SignUp.from_json(%({"name":"Ada","email":"ada@x.io","bio":"hi","admin":true,"id":5}))
      person = request.to_model(ContractBridgeSpec::Person)
      {person.name, person.email, person.bio, person.id?}.should eq({"Ada", "ada@x.io", "hi", nil})
      ContractBridgeSpec::Person.from_request(request).name.should eq "Ada"
    end

    it "honours map_to's except: and rename:" do
      request = ContractBridgeSpec::Renamed.from_json(%({"full_name":"Grace","email":"g@x.io","bio":"skipped"}))
      person = request.to_model(ContractBridgeSpec::Person)
      {person.name, person.bio}.should eq({"Grace", nil})
    end

    it "never copies id and created_at into constructor arguments either, unless only: names them" do
      request = ContractBridgeSpec::Sneaky.from_json(%({"name":"Eve","id":99,"created_at":"2000-01-01T00:00:00Z","role":"admin"}))
      plain = request.to_model(ContractBridgeSpec::Plain)
      {plain.id, plain.created_at, plain.role}.should eq({nil, nil, "admin"}) # role is mass-assigned: see only:
    end

    it "does not let a field named like a renamed attribute overwrite it" do
      request = ContractBridgeSpec::Collides.from_json(%({"full_name":"Grace","name":"other","email":"g@x.io"}))
      request.to_model(ContractBridgeSpec::Person).name.should eq "Grace"
    end

    it "builds a response, formatting Time as RFC 3339 and keeping nils" do
      person = ContractBridgeSpec::Person.new("Ada", "ada@x.io")
      person.created_at = Time.utc(2026, 1, 2, 3, 4, 5)
      response = ContractBridgeSpec::PersonResponse.from(person)
      {response.name, response.bio, response.created_at}.should eq({"Ada", nil, "2026-01-02T03:04:05Z"})
    end
  end

  describe "validation" do
    it "turns model validation errors into a 422 with field errors" do
      person = ContractBridgeSpec::Person.new("A", "nope")
      error = expect_raises(Azu::Response::ValidationError) { person.valid_or_422! }
      error.status_code.should eq 422
      error.field_errors.keys.sort!.should eq ["email", "name"]
      ContractBridgeSpec::Person.new("Ada", "a@b").valid_or_422!.name.should eq "Ada"
    end

    it "answers 422 problem+json over HTTP, and nothing is stored" do
      ContractBridgeSpec.serve do |base|
        response = ContractBridgeSpec.post(base, "/people", "Ada", "not-an-email")
        response.status_code.should eq 422
        response.headers["Content-Type"].should start_with "application/problem+json"
        JSON.parse(response.body)["errors"]["email"].as_a.size.should eq 1
        ContractBridgeSpec.names.should be_empty
      end
    end

    it "maps the error `save!` raises to a 422 in the middleware" do
      ContractBridgeSpec.serve do |base|
        ContractBridgeSpec.post(base, "/people/save", "A", "nope").status_code.should eq 422
      end
    end
  end

  describe "Azu::CQL::Middleware" do
    it "creates through request -> model -> response and commits" do
      ContractBridgeSpec.serve do |base|
        response = ContractBridgeSpec.post(base, "/people", "Ada")
        response.status_code.should eq 201
        JSON.parse(response.body)["name"].should eq "Ada"
        ContractBridgeSpec.names.should eq ["Ada"]
      end
    end

    it "rolls back on an exception and on a 5xx without one" do
      ContractBridgeSpec.serve do |base|
        ContractBridgeSpec.post(base, "/people/boom", "Ada").status_code.should eq 500
        ContractBridgeSpec.post(base, "/people/500", "Bob").status_code.should eq 500
        ContractBridgeSpec.names.should be_empty
      end
    end

    it "discards the buffered success when the commit fails, so the error page stands alone" do
      file = File.tempname("azu_cql_commit_failure", ".db") # its own database: a failed commit leaves SQLite's connection mid-transaction
      schema = Azu::CQL.schema(:commit_failure, "sqlite3://#{file}?foreign_keys=1", lazy: false) { table(:parents) { primary :id, Int64 } }
      schema.build
      schema.exec("CREATE TABLE kids (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id) DEFERRABLE INITIALLY DEFERRED)")
      orphan = ->(context : HTTP::Server::Context) do
        schema.exec("INSERT INTO kids (parent_id) VALUES (404)") # fails only at commit
        context.response.print "SUCCESS-BODY"
      end
      handler = Azu::CQL::Middleware.new(schema, transaction: true)
      handler.next = orphan
      context, io = create_context("POST", "/orphan")
      expect_raises(Exception) { handler.call(context) }
      context.response.close
      io.to_s.should_not contain "SUCCESS-BODY"
      File.delete?(file)
    end

    it "keeps the write of a failing request when it is not transactional" do
      ContractBridgeSpec.serve(transaction: false) do |base|
        ContractBridgeSpec.post(base, "/people/boom", "Ada").status_code.should eq 500
        ContractBridgeSpec.names.should eq ["Ada"]
      end
    end

    it "keeps concurrent requests apart: each commits or rolls back its own writes" do
      ContractBridgeSpec.serve do |base|
        done = Channel({String, Int32}).new
        10.times do |i|
          spawn do
            name = "user#{i}"
            done.send({name, ContractBridgeSpec.post(base, "/people/concurrent", name).status_code})
          end
        end
        results = Hash(String, Int32).new
        10.times { name, code = done.receive; results[name] = code }

        expected = (0...10).map { |i| "user#{i}" }.select(&.[-1].to_i.even?)
        results.select { |_, code| code == 200 }.keys.sort!.should eq expected
        results.count { |_, code| code == 500 }.should eq 5
        ContractBridgeSpec.names.should eq expected
      end
    end

    it "tags the statements and transactions of a request with its request id" do
      store = Azu::QueryStore.instance
      Azu::CQL.attach(ContractBridgeSpec::SCHEMA)
      store.clear
      begin
        ContractBridgeSpec.serve do |base|
          response = ContractBridgeSpec.post(base, "/people", "Ada")
          request_id = response.headers["X-Request-ID"]
          insert = store.queries.find! { |query| query.operation == "INSERT" }
          insert.request_id.should eq request_id
          store.transactions.any? { |transaction| transaction.request_id == request_id }.should be_true
        end
      ensure
        Azu::CQL::Instrumentor.uninstall
      end
    end
  end

  describe "compile-time checks" do
    it "refuses a request that cannot supply a constructor argument or has an incompatible type" do
      next pending!("crystal is not installed") unless Process.find_executable("crystal")

      missing = compile_error("getter name : String")
      missing.should contain "Person.new needs email"
      nilable = compile_error("getter name : String?\n getter email : String")
      nilable.should contain "the source may be nil"
      mismatch = compile_error("getter name : String\n getter email : Int32")
      mismatch.should contain "not convertible without loss"
    end
  end
end

private def compile_error(fields : String) : String
  dir = File.tempname("azu-bridge")
  Dir.mkdir_p(dir)
  program = File.join(dir, "main.cr")
  File.write(program, <<-CR)
    require "sqlite3"
    require "azu"
    require "azu/cql"

    BadDB = Azu::CQL.schema(:bad, "sqlite3://#{File.join(dir, "bad.db")}") { table(:people) { primary :id, Int64; column :name, String; column :email, String } }
    class Person
      include CQL::ActiveRecord::Model(Int64)
      db_context BadDB, :people
      property name : String
      property email : String
      def initialize(@name : String, @email : String); end
    end
    struct Bad
      include Azu::Request
      #{fields}
    end
    Bad.from_json("{}").to_model(Person)
    CR
  search_path = [File.expand_path("../../../src", __DIR__), File.expand_path("../../../lib", __DIR__), `crystal env CRYSTAL_PATH`.strip].join(':')
  error = IO::Memory.new
  process = Process.new("crystal", ["build", "--no-codegen", "--no-color", program], env: {"CRYSTAL_PATH" => search_path}, output: Process::Redirect::Close, error: Process::Redirect::Pipe)
  spawn { sleep 5.minutes; process.terminate rescue nil } # a stuck compiler must not hang the suite
  IO.copy(process.error, error)
  status = process.wait
  fail "the program compiled" if status.success?
  error.to_s
ensure
  FileUtils.rm_rf(dir) if dir
end

require "../../spec_helper"
require "sqlite3"
require "../../../src/azu/cql"

private DB_FILE = File.join(Dir.tempdir, "azu_cql_instrumentor_spec.db")

private def build_schema
  File.delete?(DB_FILE)
  schema = CQL::Schema.define(:azu_spec, adapter: CQL::Adapter::SQLite, uri: "sqlite3://#{DB_FILE}") do
    table :authors do
      primary :id, Int64
      column :name, String
    end
    table :books do
      primary :id, Int64
      column :author_id, Int64
      column :title, String
    end
  end
  schema.build
  schema
end

describe Azu::CQL do
  store = Azu::QueryStore.instance

  before_each do
    Azu::CQL::Instrumentor.uninstall
    store.clear
  end
  after_all { Azu::CQL::Instrumentor.uninstall }

  it "records queries tagged with the current request" do
    schema = Azu::CQL.attach(build_schema)
    store.clear
    Azu::RequestContext.with("req-42", "GET", "/authors", "AuthorsEndpoint") do
      schema.exec("INSERT INTO authors (name) VALUES ('Ada')")
      schema.query.from(:authors).select(:name).all(String)
    end

    queries = store.queries
    insert = queries.find! { |q| q.operation == "INSERT" }
    insert.request_id.should eq "req-42"
    insert.endpoint.should eq "AuthorsEndpoint"
    insert.path.should eq "/authors"
    insert.table.should eq "authors"
    insert.caller.to_s.should contain "instrumentor_spec.cr"
    select_q = queries.find! { |q| q.operation == "SELECT" }
    select_q.rows.should eq 1
    select_q.duration_ms.should be >= 0
    Azu::CQL::Instrumentor.installed?.should be_true
  end

  it "flags an N+1 loop but not an eager query" do
    schema = Azu::CQL.attach(build_schema)
    3.times { |i| schema.exec("INSERT INTO authors (name) VALUES ('a#{i}')") }
    3.times { |i| schema.exec("INSERT INTO books (author_id, title) VALUES (#{i + 1}, 't')") }
    store.clear

    Azu::RequestContext.with("req-n1", "GET", "/books") do
      ids = schema.query.from(:authors).select(:id).all(Int64)
      ids.each { |id| schema.query.from(:books).select(:id, :title).where(author_id: id).all({id: Int64, title: String}) }
    end
    alerts = store.n_plus_one(3)
    alerts.size.should eq 1
    alerts.first.request_id.should eq "req-n1"
    alerts.first.count.should eq 3

    store.clear
    Azu::RequestContext.with("req-ok", "GET", "/books") do
      schema.query.from(:books).select(:id, :title).all({id: Int64, title: String})
    end
    store.n_plus_one(3).should be_empty
  end

  it "records committed and rolled back transactions with their queries" do
    schema = Azu::CQL.attach(build_schema)
    store.clear
    schema.transaction { |_tx| schema.exec("INSERT INTO authors (name) VALUES ('ok')") }
    schema.transaction do |_tx|
      schema.exec("INSERT INTO authors (name) VALUES ('nope')")
      raise DB::Rollback.new
    end

    states = store.transactions.map(&.state)
    states.should eq ["rolled_back", "committed"]
    store.transactions.map(&.query_count).should eq [1, 1]
    store.queries.map(&.transaction_id).compact.size.should eq 2
  end

  it "exposes pool stats and the playground adapter" do
    schema = Azu::CQL.attach(build_schema)
    schema.exec("INSERT INTO authors (name) VALUES ('Grace')")
    store.pool.should_not be_nil
    adapter = store.adapter.not_nil!
    adapter.dialect.should eq "sqlite"
    columns, rows = adapter.read_only("SELECT name FROM authors", 10)
    columns.should eq ["name"]
    rows.should eq [["Grace"]]
    adapter.read_only("SELECT count(*) FROM authors", 10)[1].size.should eq 1
  end

  it "honours database.instrument = false" do
    schema = Azu::CQL.attach(build_schema)
    store.clear
    Azu::CONFIG.database.instrument = false
    begin
      schema.exec("SELECT 1")
      store.queries.should be_empty
    ensure
      Azu::CONFIG.database.instrument = true
    end
  end

  it "picks the adapter from the uri" do
    Azu::CQL.adapter_for("postgres://localhost/x").should eq CQL::Adapter::Postgres
    Azu::CQL.adapter_for("sqlite3://./x.db").should eq CQL::Adapter::SQLite
  end
  it "defines a schema from a uri and attaches it" do
    File.delete?(DB_FILE)
    schema = Azu::CQL.schema(:azu_spec_zero_config, "sqlite3://#{DB_FILE}") do
      table :things do
        primary :id, Int64
        column :name, String
      end
    end
    schema.build
    Azu::CQL::Instrumentor.installed?.should be_true
    store.adapter.should_not be_nil
    schema.exec("INSERT INTO things (name) VALUES ('x')")
    store.queries.any? { |query| query.table == "things" }.should be_true
  end

  it "keeps CQL types resolvable when Azu is included in an app namespace" do
    # CQL's own macros expand `CQL::ActiveRecord::...` inside the app's namespace
    Azu::CQL::ActiveRecord::Model.should eq ::CQL::ActiveRecord::Model
    Azu::CQL::Schema.should eq ::CQL::Schema
    Azu::CQL::Adapter::SQLite.should eq ::CQL::Adapter::SQLite
  end
end

require "../spec_helper"
require "../support/openapi_validator"
require "http/client"
require "uuid/json"

module OpenAPISpec
  enum Role
    Admin
    Member
  end

  struct Address
    include JSON::Serializable
    include URI::Params::Serializable

    property city : String
    property zip : String?

    def initialize(@city : String, @zip : String? = nil)
    end
  end

  struct UserView
    include Azu::Response
    include JSON::Serializable

    property id : Int64
    property name : String
    property role : Role
    property address : Address?
    property token : UUID?

    def initialize(@id : Int64 = 1, @name : String = "n", @role : Role = Role::Member, @address : Address? = nil, @token : UUID? = nil)
    end

    def render
      to_json
    end
  end

  struct UserList
    include Azu::Response
    include JSON::Serializable

    property users : Array(UserView)
    property total : Int64

    def initialize(@users : Array(UserView) = [] of UserView, @total : Int64 = 0)
    end

    def render
      to_json
    end
  end

  struct Stats
    include Azu::Response
    include JSON::Serializable

    property users : Int32

    def initialize(@users : Int32 = 3)
    end

    def render
      to_json
    end
  end

  # Not JSON::Serializable: the document cannot know what it renders.
  struct Text
    include Azu::Response

    def render
      "gone"
    end
  end

  struct ListRequest
    include Azu::Request

    getter page : Int32 = 1
    getter q : String?
    getter role : Role?

    validate page, gte: 1, lte: 100

    def initialize(@page = 1, @q = nil, @role = nil)
    end
  end

  struct CreateRequest
    include Azu::Request

    getter name : String
    getter email : String
    getter age : Int32 = 0
    getter role : Role
    getter tags : Array(String) = [] of String
    getter address : Address?
    getter? newsletter : Bool = false
    getter ratio : Float64?
    getter joined : Time?

    validate name, presence: true, size: 2..50
    validate email, match: /@/
    validate age, gte: 0

    def initialize(@name = "", @email = "", @age = 0, @role = Role::Member)
    end
  end

  struct ShowRequest
    include Azu::Request

    getter id : Int64

    def initialize(@id = 0_i64)
    end
  end

  module Users
    struct ListEndpoint
      include Azu::Endpoint(ListRequest, UserList)

      def call : UserList
        content_type "application/json"
        UserList.new
      end
    end

    struct CreateEndpoint
      include Azu::Endpoint(CreateRequest, UserView)

      def call : UserView
        content_type "application/json"
        UserView.new
      end
    end

    struct ShowEndpoint
      include Azu::Endpoint(ShowRequest, UserView)

      def call : UserView
        content_type "application/json"
        UserView.new(show_request.id)
      end
    end

    struct DeleteEndpoint
      include Azu::Endpoint(ShowRequest, Text)

      def call : Text
        Text.new
      end
    end
  end

  module Admin
    struct StatsEndpoint
      include Azu::Endpoint(Azu::Request, Stats)

      def call : Stats
        content_type "application/json"
        Stats.new
      end
    end
  end

  # Routed but hand written: no operation.
  struct Ping
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      context.response << "pong"
      context
    end
  end

  class LiveChannel < Azu::Channel
    def on_connect
    end

    def on_message(message : String)
    end

    def on_binary(binary : Bytes)
    end

    def on_ping(message : String)
    end

    def on_pong(message : String)
    end

    def on_close(code, message)
    end
  end

  def self.app : Azu::App
    admin = Azu::App.new
    admin.routes { get "/stats", Admin::StatsEndpoint }

    app = Azu::App.new
    app.routes do
      get "/ping", Ping.new
      ws "/live", LiveChannel
      scope "/api" do
        get "/users", Users::ListEndpoint
        post "/users", Users::CreateEndpoint
        get "/users/:id", Users::ShowEndpoint
        delete "/users/:id", Users::DeleteEndpoint
      end
      mount admin, at: "/admin"
    end
    app
  end

  def self.info : Azu::OpenAPI::Info
    Azu::OpenAPI::Info.new("Spec API", "1.2.3", description: "A spec")
  end

  def self.servers : Array(Azu::OpenAPI::Server)
    [Azu::OpenAPI::Server.new("https://api.example.com", "production")]
  end

  OK = %({"description": "Successful response"})

  def self.json_ok(schema : String) : String
    %({"description": "Successful response", "content": {"application/json": {"schema": #{schema}}}})
  end

  def self.ref(name : String) : String
    %({"$ref": "#/components/schemas/#{name}"})
  end

  ERRORS_400_422 = %("400": {"$ref": "#/components/responses/BadRequest"}, "422": {"$ref": "#/components/responses/ValidationFailed"})

  def self.expected : JSON::Any
    JSON.parse(<<-JSON)
      {
        "openapi": "3.1.0",
        "info": {"title": "Spec API", "version": "1.2.3", "description": "A spec"},
        "servers": [{"url": "https://api.example.com", "description": "production"}],
        "paths": {
          "/admin/stats": {
            "get": {
              "operationId": "OpenAPISpec.Admin.StatsEndpoint",
              "tags": ["Admin"],
              "responses": {"200": #{json_ok(ref("OpenAPISpec.Stats"))}}
            }
          },
          "/api/users": {
            "get": {
              "operationId": "OpenAPISpec.Users.ListEndpoint",
              "tags": ["Users"],
              "parameters": [
                {"name": "page", "in": "query", "required": false, "schema": {"type": "integer", "format": "int32", "minimum": 1, "maximum": 100}},
                {"name": "q", "in": "query", "required": false, "schema": {"type": "string"}},
                {"name": "role", "in": "query", "required": false, "schema": {"type": "string", "enum": ["admin", "member"]}}
              ],
              "responses": {"200": #{json_ok(ref("OpenAPISpec.UserList"))}, #{ERRORS_400_422}}
            },
            "post": {
              "operationId": "OpenAPISpec.Users.CreateEndpoint",
              "tags": ["Users"],
              "requestBody": {
                "required": true,
                "content": {
                  "application/json": {"schema": #{create_schema}},
                  "application/x-www-form-urlencoded": {"schema": #{create_schema}}
                }
              },
              "responses": {"200": #{json_ok(ref("OpenAPISpec.UserView"))}, #{ERRORS_400_422}}
            }
          },
          "/api/users/{id}": {
            "get": {
              "operationId": "OpenAPISpec.Users.ShowEndpoint",
              "tags": ["Users"],
              "parameters": [{"name": "id", "in": "path", "required": true, "schema": {"type": "integer", "format": "int64"}}],
              "responses": {"200": #{json_ok(ref("OpenAPISpec.UserView"))}, #{ERRORS_400_422}, "404": {"$ref": "#/components/responses/NotFound"}}
            },
            "delete": {
              "operationId": "OpenAPISpec.Users.DeleteEndpoint",
              "tags": ["Users"],
              "parameters": [{"name": "id", "in": "path", "required": true, "schema": {"type": "integer", "format": "int64"}}],
              "responses": {"200": #{OK}, #{ERRORS_400_422}, "404": {"$ref": "#/components/responses/NotFound"}}
            }
          }
        },
        "components": {
          "responses": {
            "BadRequest": {"description": "The request could not be parsed.", "content": {"application/json": {"schema": #{ref("Azu.Error")}}}},
            "NotFound": {"description": "Nothing is routed there, or the endpoint found nothing.", "content": {"application/json": {"schema": #{ref("Azu.Error")}}}},
            "ValidationFailed": {"description": "The request broke its contract.", "content": {"application/problem+json": {"schema": #{ref("Azu.ValidationProblem")}}}}
          },
          "schemas": {
            "Azu.Error": {
              "type": "object",
              "properties": {
                "Backtrace": {"type": ["string", "null"]},
                "Context": {"type": ["object", "null"]},
                "Detail": {"type": "string"},
                "ErrorId": {"type": "string"},
                "Errors": {"type": "array", "items": {"type": "string"}},
                "Fingerprint": {"type": "string"},
                "Link": {"type": "string"},
                "Source": {"type": "string"},
                "Status": {"type": "string", "description": "The HTTP::Status member name, underscored, such as not_found."},
                "Timestamp": {"type": "string", "format": "date-time"},
                "Title": {"type": "string"}
              }
            },
            "Azu.ValidationProblem": {
              "type": "object",
              "properties": {
                "detail": {"type": "string"},
                "errors": {"type": "object", "additionalProperties": {"type": "array", "items": {"type": "string"}}},
                "status": {"type": "integer"},
                "title": {"type": "string"},
                "type": {"type": "string"}
              },
              "required": ["type", "title", "status", "detail", "errors"]
            },
            "OpenAPISpec.Address": {
              "type": "object",
              "properties": {"city": {"type": "string"}, "zip": {"type": "string"}},
              "required": ["city"]
            },
            "OpenAPISpec.Stats": {
              "type": "object",
              "properties": {"users": {"type": "integer", "format": "int32"}},
              "required": ["users"]
            },
            "OpenAPISpec.UserList": {
              "type": "object",
              "properties": {
                "total": {"type": "integer", "format": "int64"},
                "users": {"type": "array", "items": #{ref("OpenAPISpec.UserView")}}
              },
              "required": ["users", "total"]
            },
            "OpenAPISpec.UserView": {
              "type": "object",
              "properties": {
                "address": #{ref("OpenAPISpec.Address")},
                "id": {"type": "integer", "format": "int64"},
                "name": {"type": "string"},
                "role": {"type": "string", "enum": ["admin", "member"]},
                "token": {"type": "string", "format": "uuid"}
              },
              "required": ["id", "name", "role"]
            }
          }
        }
      }
      JSON
  end

  def self.create_schema : String
    <<-JSON
      {
        "type": "object",
        "properties": {
          "address": #{ref("OpenAPISpec.Address")},
          "age": {"type": "integer", "format": "int32", "minimum": 0},
          "email": {"type": "string", "pattern": "@"},
          "joined": {"type": "string", "format": "date-time"},
          "name": {"type": "string", "minLength": 2, "maxLength": 50},
          "newsletter": {"type": "boolean"},
          "ratio": {"type": "number", "format": "double"},
          "role": {"type": "string", "enum": ["admin", "member"]},
          "tags": {"type": "array", "items": {"type": "string"}}
        },
        "required": ["name", "email", "role"]
      }
      JSON
  end
end

private def serve(app : Azu::App, handlers : Array(HTTP::Handler) = [] of HTTP::Handler, &)
  server = app.server(handlers)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield HTTP::Client.new(address.address, address.port)
  ensure
    server.close
  end
end

private def document : JSON::Any
  JSON.parse(Azu::OpenAPI.document(OpenAPISpec.app, OpenAPISpec.info, OpenAPISpec.servers).to_json)
end

describe OpenAPIValidator do
  it "finds what a broken document gets wrong" do
    broken = JSON.parse(<<-JSON)
      {
        "openapi": "3.0.3",
        "info": {"title": "x"},
        "components": {"schemas": {"Page(User)": {}}},
        "paths": {
          "users": {},
          "/a/{id}": {
            "get": {"operationId": "dup", "responses": {"200": {"$ref": "#/components/schemas/Missing"}}},
            "post": {"operationId": "dup", "requestBody": {}, "parameters": [{"name": "q", "in": "query", "schema": {"type": "text"}}], "responses": {"ok": {"description": "x"}}},
            "delete": {"operationId": "Page(User)", "requestBody": {}, "responses": {"200": {"description": "x"}}}
          }
        }
      }
      JSON

    problems = OpenAPIValidator.problems(broken).join("\n")
    ["3.1.x version", "info.version", "users must start with /", "operationId dup is not unique", "path parameter id is not declared", "$ref #/components/schemas/Missing does not resolve", "ok is not a status code", "delete /a/{id}: delete must not have a requestBody", "not a JSON Schema type", "operationId Page(User) has characters", "components.schemas.Page(User) is not a valid component name"].each do |expected|
      problems.downcase.should contain expected.downcase
    end
  end
end

describe Azu::OpenAPI do
  describe ".document" do
    it "describes the endpoints of an app, its scopes and its mounted apps" do
      document.should eq OpenAPISpec.expected
    end

    it "is a structurally valid OpenAPI 3.1 document" do
      OpenAPIValidator.problems(document).should be_empty
    end

    it "is deterministic: sorted keys and the same bytes every time" do
      app = OpenAPISpec.app
      first = Azu::OpenAPI.document(app, OpenAPISpec.info).to_json
      Azu::OpenAPI.document(app, OpenAPISpec.info).to_json.should eq first

      parsed = JSON.parse(first)
      parsed.as_h.keys.should eq parsed.as_h.keys.sort!
      parsed["components"]["schemas"].as_h.keys.should eq parsed["components"]["schemas"].as_h.keys.sort!
    end

    it "leaves out what it cannot describe: hand written routables and WebSocket channels" do
      paths = document["paths"].as_h.keys
      paths.should_not contain "/ping"
      paths.should_not contain "/live"
    end

    it "lists a GET once, not with the HEAD and OPTIONS routes registered for it" do
      document["paths"]["/api/users"].as_h.keys.sort!.should eq %w(get post)
    end

    it "gives a response that is not JSON::Serializable no body schema" do
      document["paths"]["/api/users/{id}"]["delete"]["responses"]["200"].as_h.has_key?("content").should be_false
    end

    it "prefixes mounted apps below every mount above them" do
      inner = Azu::App.new
      inner.routes { get "/deep", OpenAPISpec::Admin::StatsEndpoint }
      middle = Azu::App.new
      middle.routes { mount inner, at: "/inner" }
      outer = Azu::App.new
      outer.routes { mount middle, at: "/middle" }

      paths = JSON.parse(Azu::OpenAPI.document(outer, OpenAPISpec.info).to_json)["paths"].as_h.keys
      paths.should eq ["/middle/inner/deep"]
    end

    it "keeps operation ids unique when one endpoint is routed twice" do
      app = Azu::App.new
      app.routes do
        get "/a", OpenAPISpec::Admin::StatsEndpoint
        get "/b", OpenAPISpec::Admin::StatsEndpoint
      end
      parsed = JSON.parse(Azu::OpenAPI.document(app, OpenAPISpec.info).to_json)
      ids = parsed["paths"].as_h.values.map(&.["get"]["operationId"].as_s)
      ids.uniq.size.should eq 2
      OpenAPIValidator.problems(parsed).should be_empty
    end

    it "omits servers and components when there is nothing to put in them" do
      parsed = JSON.parse(Azu::OpenAPI.document(Azu::App.new, OpenAPISpec.info).to_json)
      parsed.as_h.keys.sort!.should eq %w(info openapi paths)
      parsed["paths"].as_h.should be_empty
    end

    it "gives endpoints an operation and hand written routables none" do
      OpenAPISpec::Users::ListEndpoint.new.openapi_operation.try(&.operation_id).should eq "OpenAPISpec.Users.ListEndpoint"
      OpenAPISpec::Ping.new.openapi_operation.should be_nil
    end
  end

  describe "constraints from validate" do
    it "maps presence, required, size, comparisons, inclusion, exclusion, equality and patterns" do
      operation = Azu::OpenAPI::Operation.of(OpenAPISpec::Users::ListEndpoint, ConstraintSpec::Request, OpenAPISpec::Text)
      JSON.parse(Azu::OpenAPI.encode(operation.request_schema)).should eq JSON.parse(ConstraintSpec::EXPECTED)
    end
  end

  describe Azu::OpenAPI::Handler do
    it "serves the document as JSON at its path" do
      handler = Azu::OpenAPI::Handler.new(OpenAPISpec.app, info: OpenAPISpec.info, servers: OpenAPISpec.servers)
      serve(OpenAPISpec.app, [handler] of HTTP::Handler) do |client|
        response = client.get("/openapi.json")
        response.status_code.should eq 200
        response.content_type.should eq "application/json"
        JSON.parse(response.body).should eq OpenAPISpec.expected
      end
    end

    it "serves what the app it was given declares, from a custom path, and passes other requests on" do
      app = OpenAPISpec.app
      handler = Azu::OpenAPI::Handler.new(app, path: "/docs/api.json", info: OpenAPISpec.info)
      serve(app, [handler] of HTTP::Handler) do |client|
        client.get("/docs/api.json").status_code.should eq 200
        client.get("/openapi.json").status_code.should eq 404
        client.head("/docs/api.json").body.should be_empty
        client.post("/docs/api.json", body: "").status_code.should_not eq 200
      end
    end

    it "builds the document once and serves the same bytes afterwards" do
      app = Azu::App.new
      handler = Azu::OpenAPI::Handler.new(app, info: OpenAPISpec.info)
      serve(app, [handler] of HTTP::Handler) do |client|
        first = client.get("/openapi.json").body
        app.routes { get "/late", OpenAPISpec::Admin::StatsEndpoint }
        client.get("/openapi.json").body.should eq first
      end
    end
  end

  describe "the error components" do
    it "match the bodies the app really answers with" do
      app = OpenAPISpec.app
      schemas = document["components"]["schemas"]
      serve(app, [Azu::Handler::Rescuer.new] of HTTP::Handler) do |client|
        invalid = client.post("/api/users", HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}, %({"name": "", "email": "x", "role": "admin"}))
        invalid.status_code.should eq 422
        invalid.content_type.should eq "application/problem+json"
        body = JSON.parse(invalid.body).as_h
        (body.keys - schemas["Azu.ValidationProblem"]["properties"].as_h.keys).should be_empty
        schemas["Azu.ValidationProblem"]["required"].as_a.map(&.as_s).each { |key| body.has_key?(key).should be_true }

        missing = client.get("/nowhere", HTTP::Headers{"Accept" => "application/json"})
        missing.status_code.should eq 404
        (JSON.parse(missing.body).as_h.keys - schemas["Azu.Error"]["properties"].as_h.keys).should be_empty
      end
    end
  end
end

# Types the main fixture does not cover: recursion, generics, unions, key renames and converters.
module ExtraSpec
  struct Node
    include JSON::Serializable

    property name : String
    property children : Array(Node)
    property meta : Hash(String, Int32)
    property ref : Int32 | String

    def initialize(@name = "", @children = [] of Node, @meta = {} of String => Int32, @ref = 0)
    end
  end

  struct Page(T)
    include Azu::Response
    include JSON::Serializable

    property items : Array(T)

    def initialize(@items = [] of T)
    end

    def render
      to_json
    end
  end

  struct UpdateRequest
    include Azu::Request

    getter id : Int64

    @[JSON::Field(key: "full_name")]
    getter name : String = ""

    @[JSON::Field(converter: Time::EpochConverter)]
    getter at : Time = Time.utc

    getter ref : Int32 | String = 0

    def initialize(@id = 0_i64)
    end
  end

  struct UpdateEndpoint
    include Azu::Endpoint(UpdateRequest, OpenAPISpec::Text)

    def call : OpenAPISpec::Text
      OpenAPISpec::Text.new
    end
  end

  struct TreeEndpoint
    include Azu::Endpoint(Azu::Request, Page(Node))

    def call : Page(Node)
      Page(Node).new
    end
  end

  def self.app : Azu::App
    app = Azu::App.new
    app.routes do
      put "/items/:id", UpdateEndpoint
      get "/tree", TreeEndpoint
    end
    app
  end

  def self.document(app : Azu::App = self.app) : JSON::Any
    JSON.parse(Azu::OpenAPI.document(app, OpenAPISpec.info).to_json)
  end
end

describe "types beyond the basics" do
  document = ExtraSpec.document

  it "describes recursive types, hashes, unions and generic types with valid component names" do
    OpenAPIValidator.problems(document).should be_empty
    schemas = document["components"]["schemas"]
    schemas.as_h.keys.select(&.starts_with?("ExtraSpec.")).sort!.should eq %w(ExtraSpec.Node ExtraSpec.Page.ExtraSpec.Node)

    schemas["ExtraSpec.Node"]["properties"].should eq JSON.parse(<<-JSON)
      {
        "children": {"type": "array", "items": {"$ref": "#/components/schemas/ExtraSpec.Node"}},
        "meta": {"type": "object", "additionalProperties": {"type": "integer", "format": "int32"}},
        "name": {"type": "string"},
        "ref": {"anyOf": [{"type": "integer", "format": "int32"}, {"type": "string"}]}
      }
      JSON
    document["paths"]["/tree"]["get"]["operationId"].should eq "ExtraSpec.TreeEndpoint"
  end

  it "names a generic response type without parentheses" do
    schema = document["paths"]["/tree"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]
    schema["$ref"].should eq "#/components/schemas/ExtraSpec.Page.ExtraSpec.Node"
  end

  it "keeps path named fields in the JSON body, and leaves them out of the form that gets them from the path" do
    operation = document["paths"]["/items/{id}"]["put"]
    operation["parameters"].should eq JSON.parse(%([{"name": "id", "in": "path", "required": true, "schema": {"type": "integer", "format": "int64"}}]))

    json = operation["requestBody"]["content"]["application/json"]["schema"]
    json["required"].should eq JSON.parse(%(["id"]))
    json["properties"].as_h.keys.sort!.should eq %w(at full_name id ref)

    form = operation["requestBody"]["content"]["application/x-www-form-urlencoded"]["schema"]
    form.as_h.has_key?("required").should be_false
    form["properties"].as_h.keys.sort!.should eq %w(at name ref)
  end

  it "uses JSON::Field keys for the body only, and describes a converted field as anything" do
    json = document["paths"]["/items/{id}"]["put"]["requestBody"]["content"]["application/json"]["schema"]["properties"]
    json["at"].should eq JSON.parse("{}")
    json["full_name"].should eq JSON.parse(%({"type": "string"}))

    form = document["paths"]["/items/{id}"]["put"]["requestBody"]["content"]["application/x-www-form-urlencoded"]["schema"]["properties"]
    form["at"].should eq JSON.parse(%({"type": "string", "format": "date-time"}))
    form.as_h.has_key?("full_name").should be_false
  end

  it "uses the form keys for query parameters" do
    struct_app = Azu::App.new
    struct_app.routes { get "/items/:id", ExtraSpec::UpdateEndpoint }
    parameters = ExtraSpec.document(struct_app)["paths"]["/items/{id}"]["get"]["parameters"].as_a
    parameters.map(&.["name"].as_s).should eq %w(id name at ref)
    parameters.map(&.["in"].as_s).should eq %w(path query query query)
  end

  it "follows a Legacy error_format app: the 422 body and content type change" do
    app = OpenAPISpec.app
    app.config.error_format = Azu::ErrorFormat::Legacy
    parsed = JSON.parse(Azu::OpenAPI.document(app, OpenAPISpec.info).to_json)

    OpenAPIValidator.problems(parsed).should be_empty
    parsed["components"]["responses"]["ValidationFailed"]["content"].as_h.keys.should eq ["application/json"]
    parsed["components"]["schemas"].as_h.has_key?("Azu.ValidationProblem").should be_false

    serve(app, [Azu::Handler::Rescuer.new] of HTTP::Handler) do |client|
      response = client.post("/api/users", HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}, %({"name": "", "email": "x", "role": "admin"}))
      response.status_code.should eq 422
      keys = JSON.parse(response.body).as_h.keys
      (keys - parsed["components"]["schemas"]["Azu.LegacyValidationError"]["properties"].as_h.keys).should be_empty
    end
  end

  it "only turns :name and *name at the start of a segment into parameters" do
    app = Azu::App.new
    app.routes { get "/files/*path", OpenAPISpec::Admin::StatsEndpoint }
    ExtraSpec.document(app)["paths"].as_h.keys.should eq ["/files/{path}"]
  end

  it "keeps a colon inside a segment as part of the path" do
    app = Azu::App.new
    app.routes { get "/users:search", OpenAPISpec::Admin::StatsEndpoint }
    ExtraSpec.document(app)["paths"].as_h.keys.should eq ["/users:search"]
  end

  it "emits a path once when mounts declare it with different parameter names" do
    one = Azu::App.new
    one.routes { get "/things/:id", OpenAPISpec::Admin::StatsEndpoint }
    other = Azu::App.new
    other.routes { get "/:slug", OpenAPISpec::Admin::StatsEndpoint }
    root = Azu::App.new
    root.routes do
      mount one, at: "/m"
      mount other, at: "/m/things"
    end
    paths = ExtraSpec.document(root)["paths"].as_h.keys
    paths.size.should eq 1
    OpenAPIValidator.problems(ExtraSpec.document(root)).should be_empty
  end
end

describe Azu::OpenAPI::Constraints::Pattern do
  {
    "\\A[A-Z]+\\z"      => "^[A-Z]+$",
    "\\Aa\\Z"           => "^a$",
    "a(?:b|c)(?=d)\\d+" => "a(?:b|c)(?=d)\\d+",
    "\\\\A"             => "\\\\A",
    "(?<year>\\d+)"     => nil,
    "(?i)abc"           => nil,
    "[[:alpha:]]+"      => nil,
    "\\h+"              => nil,
    "a\\"               => nil,
  }.each do |source, expected|
    it "turns #{source} into #{expected.inspect}" do
      described_class = Azu::OpenAPI::Constraints::Pattern
      described_class.portable(source).should eq expected
    end
  end

  it "leaves out the pattern of a regular expression that has options" do
    schema = Azu::OpenAPI::Map{"type" => "string"}
    Azu::OpenAPI::Constraints.match(schema, /abc/i)
    schema.has_key?("pattern").should be_false
  end
end

describe Azu::OpenAPI::Handler do
  it "can be served at the root path" do
    app = OpenAPISpec.app
    handler = Azu::OpenAPI::Handler.new(app, path: "/", info: OpenAPISpec.info)
    serve(app, [handler] of HTTP::Handler) do |client|
      client.get("/").status_code.should eq 200
      JSON.parse(client.get("/").body)["openapi"].should eq "3.1.0"
    end
  end
end

module ConstraintSpec
  struct Request
    include Azu::Request

    getter title : String
    getter items : Array(String)
    getter count : Int32
    getter ratio : Float64
    getter code : String
    getter kind : String
    getter flag : String
    getter label : String?
    getter level : Int32
    getter tracked : String = ""

    validate title, presence: true, size: 3..8
    validate items, size: 1...4
    validate count, gt: 0, lt: 10
    validate ratio, gte: 0.5, lte: 1.5
    validate code, size: 6, match: /\A[A-Z]+\z/
    validate kind, in: %w(a b), exclude: %w(c)
    validate flag, eq: "yes"
    validate label, required: true
    validate level, in: 1..5
    validate tracked, size: 2..

    def initialize(@title = "", @items = [] of String, @count = 1, @ratio = 1.0, @code = "", @kind = "a", @flag = "yes", @label = nil, @level = 1, @tracked = "")
    end
  end

  EXPECTED = <<-JSON
    {
      "type": "object",
      "properties": {
        "code": {"type": "string", "minLength": 6, "maxLength": 6, "pattern": "^[A-Z]+$"},
        "count": {"type": "integer", "format": "int32", "exclusiveMinimum": 0, "exclusiveMaximum": 10},
        "flag": {"type": "string", "const": "yes"},
        "items": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 3},
        "kind": {"type": "string", "enum": ["a", "b"], "not": {"enum": ["c"]}},
        "label": {"type": "string"},
        "level": {"type": "integer", "format": "int32", "minimum": 1, "maximum": 5},
        "ratio": {"type": "number", "format": "double", "minimum": 0.5, "maximum": 1.5},
        "title": {"type": "string", "minLength": 3, "maxLength": 8},
        "tracked": {"type": "string", "minLength": 2}
      },
      "required": ["title", "items", "count", "ratio", "code", "kind", "flag", "label", "level"]
    }
    JSON
end

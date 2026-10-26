require "../spec_helper"
require "../../src/azu/testing/testing"

module OpenAPIDocsSpec
  struct Address
    include JSON::Serializable

    getter city : String
    getter zip : String?
  end

  struct UserRequest
    include Azu::Request

    getter id : Int64 = 0_i64
    getter name : String
    getter tags : Array(String) = [] of String

    validate name, presence: true, size: 2..50

    def initialize(@name = "")
    end
  end

  struct UserView
    include Azu::Response
    include JSON::Serializable

    getter name : String
    getter address : Address?

    def initialize(@name : String, @address : Address? = nil)
    end

    def render
      to_json
    end
  end

  module Users
    struct CreateEndpoint
      include Azu::Endpoint(UserRequest, UserView)

      def call : UserView
        UserView.new(user_request.name)
      end
    end

    struct ShowEndpoint
      include Azu::Endpoint(UserRequest, UserView)

      def call : UserView
        UserView.new(user_request.name)
      end
    end
  end

  def self.app : Azu::App
    app = Azu::App.new
    app.routes do
      post "/users", Users::CreateEndpoint
      get "/users/:id", Users::ShowEndpoint
    end
    app
  end

  def self.client(docs : String? = nil) : Azu::Testing::Client
    app = self.app
    handler = Azu::OpenAPI::Handler.new(app, info: info, docs: docs)
    Azu::Testing::Client.new(app, [handler] of HTTP::Handler)
  end

  def self.info(title = "Shop <API>") : Azu::OpenAPI::Info
    Azu::OpenAPI::Info.new(title, "2.0.0", description: "Buy & sell")
  end
end

describe "Azu::OpenAPI::Handler docs page" do
  it "is off unless a docs path is given" do
    OpenAPIDocsSpec.client.get("/docs").status_code.should eq 404
  end

  it "serves an HTML page with no script and a policy that allows only its own style" do
    response = OpenAPIDocsSpec.client("/docs/").get("/docs")

    response.status_code.should eq 200
    response.content_type.should eq "text/html"
    response.body.should_not contain "<script"
    response.body.should_not contain "http"
    policy = response.header("Content-Security-Policy").not_nil!
    policy.should start_with "default-src 'none'; style-src 'sha256-"
    style = response.body[/<style>(.*?)<\/style>/m, 1]
    policy.should contain Base64.strict_encode(Digest::SHA256.digest(style))
    response.header("Content-Length").should eq response.body.bytesize.to_s
  end

  it "answers HEAD without a body and passes other methods on" do
    client = OpenAPIDocsSpec.client("/docs")
    head = client.head("/docs")
    head.status_code.should eq 200
    head.body.should be_empty
    client.post("/docs").status_code.should eq 404
  end

  it "lists every operation with its parameters, body and responses, escaped" do
    body = OpenAPIDocsSpec.client("/docs").get("/docs").body

    body.should contain "<title>Shop &lt;API&gt; 2.0.0</title>"
    body.should contain "Buy &amp; sell"
    body.should_not contain "Shop <API>"
    body.should contain %(<a href="/openapi.json">)
    body.should contain %(<span class="method post">POST</span> <code>/users</code>)
    body.should contain %(<span class="method get">GET</span> <code>/users/{id}</code>)
    body.should contain "OpenAPIDocsSpec.Users.ShowEndpoint"
    body.should match /<td><code>id<\/code><\/td><td>path<\/td><td>yes<\/td><td>integer \(int64\)<\/td>/
    body.should contain "string, minLength 2, maxLength 50"
    body.should contain "array of string"
    body.should contain "application/x-www-form-urlencoded"
    body.should contain "422"
  end

  it "describes the shared schemas and links to them" do
    body = OpenAPIDocsSpec.client("/docs").get("/docs").body

    body.should contain %(<a href="#schema-OpenAPIDocsSpec.UserView">OpenAPIDocsSpec.UserView</a>)
    body.should contain %(<section class="schema" id="schema-OpenAPIDocsSpec.Address">)
    body.should match /<td><code>city<\/code><\/td><td>yes<\/td><td>string<\/td>/
    body.should match /<td><code>zip<\/code><\/td><td>no<\/td><td>string<\/td>/
  end

  it "refuses a docs path that is the document's own" do
    expect_raises(ArgumentError, /docs/) do
      Azu::OpenAPI::Handler.new(OpenAPIDocsSpec.app, info: OpenAPIDocsSpec.info, docs: "/openapi.json/")
    end
  end
end

require "../spec_helper"
require "../../src/azu/testing/testing"

module ContractSpec
  struct SignupRequest
    include Azu::Request

    getter name : String
    getter email : String

    validate name, presence: true, message: "must be present"
    validate email, presence: true, message: "must be present"

    def initialize(@name = "", @email = "")
    end
  end

  struct SignupResponse
    include Azu::Response

    def initialize(@name : String)
    end

    def render
      {name: @name}.to_json
    end
  end

  # Never looks at its request: the contract must still hold.
  struct SignupEndpoint
    include Azu::Endpoint(SignupRequest, SignupResponse)

    def call : SignupResponse
      content_type "application/json"
      SignupResponse.new "reached"
    end
  end

  # One instance serves every request, so nothing parsed for one request may reach the next.
  class SharedSignupEndpoint
    include Azu::Endpoint(SignupRequest, SignupResponse)

    def call : SignupResponse
      content_type "application/json"
      SignupResponse.new signup_request.name
    end
  end

  # No fields and no rules: nothing for the contract to read or check.
  struct FieldlessRequest
    include Azu::Request
  end

  struct PageEndpoint
    include Azu::Endpoint(FieldlessRequest, SignupResponse)

    def call : SignupResponse
      content_type "application/json"
      SignupResponse.new params["page"]
    end
  end

  class AlwaysInvalid < Schema::Validator
    def initialize(@record : RuledFieldlessRequest)
    end

    def valid? : Array(Schema::Error)
      [Schema::Error.new(:base, "is never valid")]
    end
  end

  # Still no fields, but a rule that refuses every request.
  struct RuledFieldlessRequest
    include Azu::Request

    use AlwaysInvalid
  end

  struct RuledEndpoint
    include Azu::Endpoint(RuledFieldlessRequest, SignupResponse)

    def call : SignupResponse
      content_type "application/json"
      SignupResponse.new "reached"
    end
  end
end

private def post(app : Azu::App, body : String, accept : String = "application/json", handlers : Array(HTTP::Handler) = [Azu::Handler::Rescuer.new] of HTTP::Handler) : Azu::Testing::Response
  Azu::Testing::Client.new(app, handlers).post("/signup", headers: {"Content-Type" => "application/json", "Accept" => accept}, body: body)
end

private def signup_app : Azu::App
  app = Azu::App.new
  app.routes { post "/signup", ContractSpec::SignupEndpoint }
  app
end

private def page_app : Azu::App
  app = Azu::App.new
  app.routes do
    get "/page", ContractSpec::PageEndpoint
    post "/page", ContractSpec::PageEndpoint
  end
  app
end

private def ruled_app : Azu::App
  app = Azu::App.new
  app.routes { get "/ruled", ContractSpec::RuledEndpoint }
  app
end

describe "request contracts" do
  it "answers 422 problem+json with the failing fields and never calls the endpoint" do
    response = post(signup_app, %({"name": "", "email": "a@b.c"}))

    response.status_code.should eq 422
    response.content_type.should eq "application/json"
    body = JSON.parse(response.body)
    body["status"].should eq 422
    body["errors"]["name"].should eq ["must be present"]
    body["errors"].as_h.has_key?("email").should be_false
  end

  it "answers 422 and 400 on its own when no Rescuer is in the handler stack" do
    bare = [] of HTTP::Handler

    invalid = post(signup_app, %({"name": "", "email": "a@b.c"}), handlers: bare)
    invalid.status_code.should eq 422
    JSON.parse(invalid.body)["errors"]["name"].should eq ["must be present"]

    post(signup_app, "{nope", handlers: bare).status_code.should eq 400
  end

  it "does not carry a parsed request from one call to the next on a shared endpoint instance" do
    app = Azu::App.new
    app.routes { post "/signup", ContractSpec::SharedSignupEndpoint }

    post(app, %({"name": "first", "email": "a@b.c"})).body.should contain "first"
    post(app, %({"name": "", "email": "a@b.c"})).status_code.should eq 422
    post(app, %({"name": "third", "email": "a@b.c"})).body.should contain "third"
  end

  it "labels the 422 application/problem+json for a client that names it in Accept" do
    response = post(signup_app, %({"name": "", "email": "a@b.c"}), "application/problem+json")

    response.status_code.should eq 422
    response.content_type.should eq "application/problem+json"
    JSON.parse(response.body)["errors"]["name"].should eq ["must be present"]
  end

  it "lets a valid request through" do
    post(signup_app, %({"name": "n", "email": "a@b.c"})).status_code.should eq 200
  end

  it "answers 400 for a body that is not JSON" do
    post(signup_app, "{nope").status_code.should eq 400
  end

  it "keeps the pre-0.6 body behind error_format = Legacy" do
    app = signup_app
    app.config.error_format = Azu::ErrorFormat::Legacy
    response = post(app, %({"name": "", "email": ""}))

    response.status_code.should eq 422
    response.content_type.should eq "application/json"
    JSON.parse(response.body)["FieldErrors"]["name"].should eq ["must be present"]
  end
end

describe "fieldless request contracts" do
  it "leaves the query string to params" do
    response = Azu::Testing::Client.new(page_app).get("/page?page=2")

    response.status_code.should eq 200
    JSON.parse(response.body)["name"].should eq "2"
  end

  it "answers 400 for a body that is not JSON" do
    response = Azu::Testing::Client.new(page_app).post("/page", headers: {"Content-Type" => "application/json"}, body: "{bad")

    response.status_code.should eq 400
  end

  it "answers 422 when a Schema validator it uses refuses the request" do
    response = Azu::Testing::Client.new(ruled_app).get("/ruled", headers: {"Accept" => "application/json"})

    response.status_code.should eq 422
    JSON.parse(response.body)["errors"]["base"].should eq ["is never valid"]
  end
end

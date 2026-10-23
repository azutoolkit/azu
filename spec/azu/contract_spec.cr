require "../spec_helper"
require "http/client"

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
end

private def post(app : Azu::App, body : String, accept : String = "application/json") : HTTP::Client::Response
  server = app.server([Azu::Handler::Rescuer.new] of HTTP::Handler)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    HTTP::Client.new(address.address, address.port).post("/signup", HTTP::Headers{"Content-Type" => "application/json", "Accept" => accept}, body)
  ensure
    server.close
  end
end

private def signup_app : Azu::App
  app = Azu::App.new
  app.routes { post "/signup", ContractSpec::SignupEndpoint }
  app
end

describe "request contracts" do
  it "answers 422 problem+json with the failing fields and never calls the endpoint" do
    response = post(signup_app, %({"name": "", "email": "a@b.c"}))

    response.status_code.should eq 422
    response.content_type.should eq "application/problem+json"
    body = JSON.parse(response.body)
    body["status"].should eq 422
    body["errors"]["name"].should eq ["must be present"]
    body["errors"].as_h.has_key?("email").should be_false
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

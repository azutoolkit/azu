require "../spec_helper"
require "../../src/azu/testing/testing"

module ProblemJsonSpec
  struct Guarded
    include Azu::Endpoint(TestRequest, Azu::Response::Empty)

    get "/guarded"

    def call : Azu::Response::Empty
      raise Azu::Response::AuthenticationError.new("Sign in first")
    end
  end

  struct Exploding
    include Azu::Endpoint(TestRequest, Azu::Response::Empty)

    get "/boom"

    def call : Azu::Response::Empty
      raise "password authentication failed for user x"
    end
  end

  def self.app(env : Azu::Environment = Azu::Environment::Production) : Azu::App
    app = Azu::App.new
    app.config.env = env
    app.routes do
      get "/guarded", Guarded
      get "/boom", Exploding
    end
    app
  end

  def self.get(path : String, accept : String, app : Azu::App = self.app) : Azu::Testing::Response
    Azu::Testing::Client.new(app, [Azu::Handler::Rescuer.new] of HTTP::Handler).get(path, headers: {"Accept" => accept})
  end
end

describe "error responses for JSON clients" do
  it "answers an unrouted path with application/problem+json" do
    response = ProblemJsonSpec.get("/missing", "application/json")

    response.status_code.should eq 404
    response.content_type.should eq "application/problem+json"
    body = JSON.parse(response.body)
    body["type"].should eq "about:blank"
    body["title"].should eq "Not Found"
    body["status"].should eq 404
    body["detail"].should eq "The server can't find the requested resource."
    body["instance"].should eq "/missing"
    body["errors"].as_a.should be_empty
  end

  it "uses lower-case members and none of the old PascalCase ones" do
    body = JSON.parse(ProblemJsonSpec.get("/missing", "application/json").body).as_h
    (body.keys & %w[Status Link Title Detail Source Errors ErrorId Fingerprint Context Backtrace Timestamp]).should be_empty
  end

  it "answers a raised Response::Error the same way, with its own status" do
    response = ProblemJsonSpec.get("/guarded", "application/json")

    response.status_code.should eq 401
    response.content_type.should eq "application/problem+json"
    body = JSON.parse(response.body)
    body["title"].should eq "Authentication Required"
    body["status"].should eq 401
    body["detail"].should eq "Sign in first"
  end

  it "answers an unhandled exception as a problem and keeps its message from clients outside development" do
    response = ProblemJsonSpec.get("/boom", "application/json")

    response.status_code.should eq 500
    response.content_type.should eq "application/problem+json"
    response.body.should_not contain("password authentication")
    JSON.parse(response.body)["status"].should eq 500
  end

  it "also answers Accept: application/problem+json" do
    ProblemJsonSpec.get("/missing", "application/problem+json").content_type.should eq "application/problem+json"
  end

  it "carries the error id in the body as it does in the X-Error-ID header" do
    response = ProblemJsonSpec.get("/missing", "application/json")
    JSON.parse(response.body)["error_id"].should eq response.headers["X-Error-ID"]
  end

  it "keeps the request context and backtrace out of production bodies" do
    body = JSON.parse(ProblemJsonSpec.get("/boom", "application/json").body).as_h
    body.has_key?("backtrace").should be_false
    body.has_key?("context").should be_false
  end

  it "gives developers the backtrace" do
    body = JSON.parse(ProblemJsonSpec.get("/boom", "application/json", ProblemJsonSpec.app(Azu::Environment::Development)).body)
    body["backtrace"].as_s.should contain("password authentication")
  end

  it "keeps the pre-0.6 body behind error_format = Legacy" do
    app = ProblemJsonSpec.app
    app.config.error_format = Azu::ErrorFormat::Legacy
    response = ProblemJsonSpec.get("/missing", "application/json", app)

    response.content_type.should eq "application/json"
    JSON.parse(response.body)["Title"].should eq "Not Found"
  end

  it "leaves HTML, XML and text negotiation as it was" do
    html = ProblemJsonSpec.get("/missing", "text/html")
    html.headers["Content-Type"].should start_with "text/html"
    html.body.should contain "404"

    xml = ProblemJsonSpec.get("/missing", "application/xml")
    xml.content_type.should eq "application/xml"
    xml.body.should contain "<error"

    text = ProblemJsonSpec.get("/missing", "text/plain")
    text.content_type.should eq "text/plain"
    text.body.should contain "Title: Not Found"
  end
end

require "../spec_helper"

module Azu::EndpointSpec
  # Test response structs
  struct TestResponse
    include Azu::Response

    @content : String

    def initialize(@content : String = "test")
    end

    def render
      @content
    end
  end

  struct JsonResponse
    include Azu::Response

    @data : Hash(String, String)

    def initialize(@data : Hash(String, String))
    end

    def render
      @data.to_json
    end
  end

  # Test endpoint classes
  class BasicEndpoint
    include Azu::Endpoint(TestRequest, TestResponse)

    get "/test"

    def call : TestResponse
      TestResponse.new("basic endpoint")
    end
  end

  def self.bare_context(body : IO, query = "")
    headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
    request = HTTP::Request.new("POST", "/params#{query}", headers, body)
    io = IO::Memory.new
    {HTTP::Server::Context.new(request, HTTP::Server::Response.new(io)), io}
  end

  # Fails the example if anything reads the request body
  class UnreadableBody < IO
    getter reads = 0

    def read(slice : Bytes) : Int32
      @reads += 1
      raise IO::Error.new("the body was read")
    end

    def write(slice : Bytes) : Nil
    end
  end

  class IgnoresParamsEndpoint
    include Azu::Endpoint(Azu::Request, TestResponse)

    def call : TestResponse
      TestResponse.new("ignored")
    end
  end

  class ReadsParamsEndpoint
    include Azu::Endpoint(Azu::Request, TestResponse)

    def call : TestResponse
      TestResponse.new(params["name"])
    end
  end

  class JsonEndpoint
    include Azu::Endpoint(TestRequest, JsonResponse)

    post "/api/test"

    def call : JsonResponse
      JsonResponse.new({"status" => "success"})
    end
  end

  class CsrfEndpoint
    include Azu::Endpoint(TestRequest, TestResponse)

    post "/csrf-test"

    def call : TestResponse
      # Test CSRF methods
      _ = csrf_token
      _ = csrf_tag
      _ = csrf_metatag

      TestResponse.new("csrf tested")
    end
  end

  class HelperEndpoint
    include Azu::Endpoint(TestRequest, TestResponse)

    post "/helper-test"

    def call : TestResponse
      # Test various helper methods
      content_type("application/json")
      _ = method
      _ = header
      _ = cookies
      status(201)
      redirect("/new-location", 302)
      error("Test error", 400, ["error1", "error2"])

      TestResponse.new("helpers tested")
    end
  end

  class StatusEndpoint
    include Azu::Endpoint(TestRequest, TestResponse)

    post "/status-test"

    def call : TestResponse
      # Test status setting without redirect
      status(201)
      TestResponse.new("status tested")
    end
  end

  class ParamsEndpoint
    include Azu::Endpoint(TestRequest, TestResponse)

    post "/params-test"

    def call : TestResponse
      # Test params and request object
      _ = params
      _ = test_request
      _ = test_request_contract

      TestResponse.new("params tested")
    end
  end
end

describe Azu::Endpoint do
  describe "basic endpoint functionality" do
    it "handles GET requests" do
      endpoint = Azu::EndpointSpec::BasicEndpoint.new
      request = HTTP::Request.new("GET", "/test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      result = endpoint.call(context)

      result.should be_a(HTTP::Server::Context)
      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq "basic endpoint"
      context.response.status_code.should eq 200
    end

    it "handles POST requests" do
      endpoint = Azu::EndpointSpec::JsonEndpoint.new
      request = HTTP::Request.new("POST", "/api/test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      result = endpoint.call(context)

      result.should be_a(HTTP::Server::Context)
      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq %({"status":"success"})
    end

    it "sets endpoint name header" do
      endpoint = Azu::EndpointSpec::BasicEndpoint.new
      request = HTTP::Request.new("GET", "/test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      context.request.headers["X-Azu-Endpoint"].should eq "BasicEndpoint"
    end
  end

  describe "parameters" do
    it "does not read the body of an endpoint that never asks for parameters" do
      body = Azu::EndpointSpec::UnreadableBody.new
      context, _ = Azu::EndpointSpec.bare_context(body)
      Azu::EndpointSpec::IgnoresParamsEndpoint.new.call(context)
      context.response.status_code.should eq 200
      body.reads.should eq 0
    end

    it "parses them on first use for an endpoint that asks" do
      context, io = Azu::EndpointSpec.bare_context(IO::Memory.new("name=ada"), "?other=1")
      Azu::EndpointSpec::ReadsParamsEndpoint.new.call(context)
      context.response.close
      io.to_s.should contain("ada")
    end

    it "reads the body where the endpoint asks for it" do
      body = Azu::EndpointSpec::UnreadableBody.new
      context, _ = Azu::EndpointSpec.bare_context(body)
      expect_raises(IO::Error, "the body was read") { Azu::EndpointSpec::ReadsParamsEndpoint.new.call(context) }
      body.reads.should eq 1
    end
  end

  describe "helper methods" do
    it "sets content type" do
      endpoint = Azu::EndpointSpec::HelperEndpoint.new
      request = HTTP::Request.new("POST", "/helper-test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      context.response.headers["content_type"].should eq "application/json"
    end

    it "sets response status" do
      endpoint = Azu::EndpointSpec::StatusEndpoint.new
      request = HTTP::Request.new("POST", "/status-test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      context.response.status_code.should eq 201
    end

    it "sets response headers" do
      endpoint = Azu::EndpointSpec::HelperEndpoint.new
      request = HTTP::Request.new("POST", "/helper-test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      context.response.headers["Location"].should eq "/new-location"
    end

    it "handles redirects" do
      endpoint = Azu::EndpointSpec::HelperEndpoint.new
      request = HTTP::Request.new("POST", "/helper-test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      context.response.status_code.should eq 302
      context.response.headers["Location"].should eq "/new-location"
    end
  end

  describe "params and request objects" do
    it "provides access to params" do
      endpoint = Azu::EndpointSpec::ParamsEndpoint.new
      request = HTTP::Request.new("POST", "/params-test?name=test&email=test@example.com")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq "params tested"
    end

    it "creates request objects from query params" do
      endpoint = Azu::EndpointSpec::ParamsEndpoint.new
      request = HTTP::Request.new("POST", "/params-test?name=test&email=test@example.com&age=25")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq "params tested"
    end

    it "creates request objects from JSON body" do
      endpoint = Azu::EndpointSpec::ParamsEndpoint.new
      request = HTTP::Request.new("POST", "/params-test")
      request.headers["Content-Type"] = "application/json"
      request.body = %({"name":"test","email":"test@example.com","age":25})
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq "params tested"
    end
  end

  describe "CSRF helper methods" do
    it "generates CSRF tokens" do
      endpoint = Azu::EndpointSpec::CsrfEndpoint.new
      request = HTTP::Request.new("POST", "/csrf-test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq "csrf tested"
    end

    it "generates CSRF HTML tags" do
      endpoint = Azu::EndpointSpec::CsrfEndpoint.new
      request = HTTP::Request.new("POST", "/csrf-test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq "csrf tested"
    end

    it "generates CSRF meta tags" do
      endpoint = Azu::EndpointSpec::CsrfEndpoint.new
      request = HTTP::Request.new("POST", "/csrf-test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq "csrf tested"
    end

    it "validates CSRF tokens" do
      endpoint = Azu::EndpointSpec::CsrfEndpoint.new
      request = HTTP::Request.new("POST", "/csrf-test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq "csrf tested"
    end

    it "gets CSRF tokens from request headers" do
      endpoint = Azu::EndpointSpec::CsrfEndpoint.new
      request = HTTP::Request.new("POST", "/csrf-test")
      request.headers["X-CSRF-TOKEN"] = "test-token"
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq "csrf tested"
    end
  end

  describe "macro functionality" do
    it "generates path helpers" do
      # Test that path helpers are generated
      path = Azu::EndpointSpec::BasicEndpoint.path
      path.should eq "/test"
    end

    it "generates path helpers with parameters" do
      # Test path helpers with parameters
      Azu::EndpointSpec::BasicEndpoint.get "/test/:id"
      path = Azu::EndpointSpec::BasicEndpoint.path(id: "123")
      path.should eq "/test/123"
    end
  end

  describe "content type handling" do
    it "handles JSON requests" do
      endpoint = Azu::EndpointSpec::JsonEndpoint.new
      request = HTTP::Request.new("POST", "/api/test")
      request.headers["Content-Type"] = "application/json"
      request.body = %({"name":"test"})
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq %({"status":"success"})
    end

    it "handles form data requests" do
      endpoint = Azu::EndpointSpec::ParamsEndpoint.new
      request = HTTP::Request.new("POST", "/params-test")
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = "name=test&email=test@example.com"
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      endpoint.call(context)

      response.close
      io.rewind
      response_body = io.gets_to_end
      # Extract just the body content after headers
      body_content = response_body.split("\r\n\r\n").last
      body_content.should eq "params tested"
    end
  end
end

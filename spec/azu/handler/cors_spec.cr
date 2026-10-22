require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Handler::CORS do
  describe "initialization" do
    it "initializes with default values" do
      handler = Azu::Handler::CORS.new
      handler.should be_a(Azu::Handler::CORS)
    end

    it "initializes with custom origins" do
      handler = Azu::Handler::CORS.new(origins: ["https://example.com"])
      handler.origins.should eq(["https://example.com"])
    end

    it "initializes with regex origins" do
      handler = Azu::Handler::CORS.new(origins: [/\.example\.com$/])
      handler.origins.should be_a(Array(String | Regex))
    end

    it "initializes with custom methods" do
      handler = Azu::Handler::CORS.new(methods: ["GET", "POST"])
      handler.methods.should eq(["GET", "POST"])
    end

    it "initializes with custom headers" do
      handler = Azu::Handler::CORS.new(headers: ["Content-Type", "Authorization"])
      handler.headers.should eq(["Content-Type", "Authorization"])
    end

    it "initializes with credentials enabled" do
      handler = Azu::Handler::CORS.new(credentials: true)
      handler.credentials.should be_true
    end

    it "initializes with max_age" do
      handler = Azu::Handler::CORS.new(max_age: 3600)
      handler.max_age.should eq(3600)
    end
  end

  describe "origin validation" do
    it "allows requests without Origin header" do
      handler = Azu::Handler::CORS.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "allows requests from wildcard origin" do
      handler = Azu::Handler::CORS.new(origins: ["*"])
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      context.response.headers["Access-Control-Allow-Origin"].should eq("https://example.com")
      verify.call
    end

    it "allows requests from specific origin" do
      handler = Azu::Handler::CORS.new(origins: ["https://example.com"])
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      context.response.headers["Access-Control-Allow-Origin"].should eq("https://example.com")
      verify.call
    end

    it "allows requests from regex-matched origin" do
      handler = Azu::Handler::CORS.new(origins: [/\.example\.com$/])
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://api.example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      context.response.headers["Access-Control-Allow-Origin"].should eq("https://api.example.com")
      verify.call
    end

    it "rejects requests from non-matching origin" do
      handler = Azu::Handler::CORS.new(origins: ["https://example.com"])
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://evil.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      context.response.headers["Content-Type"].should eq("text/plain")
      verify.call
    end

    it "handles X-Origin header" do
      handler = Azu::Handler::CORS.new(origins: ["https://example.com"])
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end
  end

  describe "preflight requests" do
    it "handles OPTIONS preflight request" do
      handler = Azu::Handler::CORS.new(
        origins: ["https://example.com"],
        methods: ["POST", "PUT"],
        headers: ["Content-Type"],
        max_age: 3600
      )
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Access-Control-Request-Method"] = "POST"
      headers["Access-Control-Request-Headers"] = "Content-Type"
      context, io = create_context("OPTIONS", "/test", headers)

      handler.call(context)

      context.response.headers["Access-Control-Allow-Origin"].should eq("https://example.com")
      context.response.headers["Access-Control-Allow-Methods"].should eq("POST")
      context.response.headers["Access-Control-Allow-Headers"].should eq("Content-Type")
      context.response.headers["Access-Control-Max-Age"].should eq("3600")
      context.response.headers["Content-Length"]?.should eq("0")
      verify.call
    end

    it "rejects preflight with invalid method" do
      handler = Azu::Handler::CORS.new(
        origins: ["https://example.com"],
        methods: ["POST"],
        headers: ["Content-Type"]
      )
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Access-Control-Request-Method"] = "DELETE"
      headers["Access-Control-Request-Headers"] = "Content-Type"
      context, io = create_context("OPTIONS", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end

    it "rejects preflight with missing headers" do
      handler = Azu::Handler::CORS.new(
        origins: ["https://example.com"],
        methods: ["POST"],
        headers: ["Content-Type"]
      )
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Access-Control-Request-Method"] = "POST"
      context, io = create_context("OPTIONS", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end

    it "allows preflight with multiple headers" do
      handler = Azu::Handler::CORS.new(
        origins: ["https://example.com"],
        methods: ["POST"],
        headers: ["Content-Type", "Authorization"]
      )
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Access-Control-Request-Method"] = "POST"
      headers["Access-Control-Request-Headers"] = "Content-Type, Authorization"
      context, io = create_context("OPTIONS", "/test", headers)

      handler.call(context)

      context.response.headers["Access-Control-Allow-Headers"].should eq("Content-Type, Authorization")
      verify.call
    end
  end

  describe "credentials handling" do
    it "sets credentials header when enabled" do
      handler = Azu::Handler::CORS.new(
        origins: ["https://example.com"],
        credentials: true
      )
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.headers["Access-Control-Allow-Credentials"].should eq("true")
      verify.call
    end

    it "does not set credentials header when disabled" do
      handler = Azu::Handler::CORS.new(
        origins: ["https://example.com"],
        credentials: false
      )
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.headers.has_key?("Access-Control-Allow-Credentials").should be_false
      verify.call
    end
  end

  describe "Vary header" do
    it "sets Vary header for specific origins" do
      handler = Azu::Handler::CORS.new(origins: ["https://example.com"])
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.headers["Vary"].should eq("Origin")
      verify.call
    end

    it "does not set Vary header for wildcard origin" do
      handler = Azu::Handler::CORS.new(origins: ["*"])
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.headers.has_key?("Vary").should be_false
      verify.call
    end

    it "includes custom vary value" do
      handler = Azu::Handler::CORS.new(
        origins: ["https://example.com"],
        vary: "Accept-Encoding"
      )
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.headers["Vary"].should eq("Origin,Accept-Encoding")
      verify.call
    end
  end

  describe "expose headers" do
    it "sets expose headers when configured" do
      handler = Azu::Handler::CORS.new(
        origins: ["https://example.com"],
        expose_headers: ["X-Custom-Header", "X-Request-ID"]
      )
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.headers["Access-Control-Expose-Headers"].should eq("X-Custom-Header,X-Request-ID")
      verify.call
    end

    it "does not set expose headers when not configured" do
      handler = Azu::Handler::CORS.new(origins: ["https://example.com"])
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.headers.has_key?("Access-Control-Expose-Headers").should be_false
      verify.call
    end
  end

  describe "edge cases" do
    it "handles empty origin list" do
      handler = Azu::Handler::CORS.new(origins: [] of String)
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end

    it "handles case-insensitive header matching" do
      handler = Azu::Handler::CORS.new(
        origins: ["https://example.com"],
        methods: ["POST"],
        headers: ["Content-Type"]
      )
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Access-Control-Request-Method"] = "POST"
      headers["Access-Control-Request-Headers"] = "content-type"
      context, io = create_context("OPTIONS", "/test", headers)

      handler.call(context)

      context.response.headers.has_key?("Access-Control-Allow-Headers").should be_true
      verify.call
    end

    it "handles multiple origins with wildcard" do
      handler = Azu::Handler::CORS.new(origins: ["*", "https://example.com"])
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://other.com"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end
  end

  # The specs above inspect the in-memory response headers. A preflight response is flushed by
  # the handler, so only a real connection shows which headers actually reach the browser.
  describe "over a real connection" do
    preflight = HTTP::Headers{
      "Origin"                         => "https://app.example",
      "Access-Control-Request-Method"  => "POST",
      "Access-Control-Request-Headers" => "Content-Type",
    }

    serve = ->(cors : Azu::Handler::CORS, request : Proc(HTTP::Client, HTTP::Client::Response)) do
      server = HTTP::Server.new([cors] of HTTP::Handler) { |context| context.response.print "OK" }
      address = server.bind_unused_port
      spawn { server.listen }
      Fiber.yield

      begin
        request.call(HTTP::Client.new(address.address, address.port))
      ensure
        server.close
      end
    end

    it "sends the Allow-Origin, Vary and preflight headers in a preflight response" do
      cors = Azu::Handler::CORS.new(origins: ["https://app.example"], methods: ["POST"], headers: ["Content-Type"], max_age: 600)

      response = serve.call(cors, ->(client : HTTP::Client) { client.options("/", preflight) })

      response.status_code.should eq(200)
      response.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example")
      response.headers["Vary"]?.should eq("Origin")
      response.headers["Access-Control-Allow-Methods"]?.should eq("POST")
      response.headers["Access-Control-Allow-Headers"]?.should eq("Content-Type")
      response.headers["Access-Control-Max-Age"]?.should eq("600")
    end

    it "sends Allow-Credentials in a preflight response when credentials are enabled" do
      cors = Azu::Handler::CORS.new(origins: ["https://app.example"], methods: ["POST"], headers: ["Content-Type"], credentials: true)

      response = serve.call(cors, ->(client : HTTP::Client) { client.options("/", preflight) })

      response.headers["Access-Control-Allow-Credentials"]?.should eq("true")
    end

    it "sends the Allow-Origin header with an actual request" do
      cors = Azu::Handler::CORS.new(origins: ["https://app.example"])

      response = serve.call(cors, ->(client : HTTP::Client) { client.get("/", HTTP::Headers{"Origin" => "https://app.example"}) })

      response.body.should eq("OK")
      response.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example")
    end

    it "grants nothing to a preflight for a method that is not allowed" do
      cors = Azu::Handler::CORS.new(origins: ["https://app.example"], methods: ["PUT"], headers: ["Content-Type"])

      response = serve.call(cors, ->(client : HTTP::Client) { client.options("/", preflight) })

      response.status_code.should eq(403)
      response.headers["Access-Control-Allow-Origin"]?.should be_nil
      response.headers["Access-Control-Allow-Methods"]?.should be_nil
    end

    it "grants nothing to an origin that is not allowed" do
      cors = Azu::Handler::CORS.new(origins: ["https://other.example"], methods: ["POST"], headers: ["Content-Type"])

      response = serve.call(cors, ->(client : HTTP::Client) { client.options("/", preflight) })

      response.status_code.should eq(403)
      response.headers["Access-Control-Allow-Origin"]?.should be_nil
    end
  end
end

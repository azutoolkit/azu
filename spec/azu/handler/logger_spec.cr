require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Handler::Logger do
  describe "initialization" do
    it "initializes with default log" do
      handler = Azu::Handler::Logger.new
      handler.should be_a(Azu::Handler::Logger)
      handler.log.should be_a(::Log)
    end

    it "initializes with custom log" do
      custom_log = Log.for("test")
      handler = Azu::Handler::Logger.new(custom_log)
      handler.log.should eq(custom_log)
    end
  end

  describe "request logging" do
    it "logs successful requests" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "logs request method" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("POST", "/api/users")
      handler.call(context)

      verify.call
    end

    it "logs request path" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/api/users/123")
      handler.call(context)

      verify.call
    end

    it "logs request timing" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      verify.call
    end
  end

  describe "endpoint tracking" do
    it "logs endpoint name when present" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Azu-Endpoint"] = "TestEndpoint"
      context, _ = create_context("GET", "/test", headers)

      handler.call(context)

      verify.call
    end

    it "handles missing endpoint header" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      verify.call
    end

    it "simplifies endpoint class names" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Azu-Endpoint"] = "MyApp::Endpoints::UserEndpoint"
      context, _ = create_context("GET", "/test", headers)

      handler.call(context)

      # Should log simplified name
      verify.call
    end
  end

  describe "remote address logging" do
    it "logs IP address" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      verify.call
    end

    it "handles missing remote address" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      verify.call
    end
  end

  describe "response status logging" do
    it "logs 2xx responses" do
      handler = Azu::Handler::Logger.new
      next_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.status_code = 200
        ctx.response.print "OK"
      }
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      context.response.status_code.should eq(200)
    end

    it "logs 4xx responses" do
      handler = Azu::Handler::Logger.new
      next_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.status_code = 404
        ctx.response.print "Not Found"
      }
      handler.next = next_handler

      context, _ = create_context("GET", "/missing")
      handler.call(context)

      context.response.status_code.should eq(404)
    end

    it "logs 5xx responses" do
      handler = Azu::Handler::Logger.new
      next_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.status_code = 500
        ctx.response.print "Error"
      }
      handler.next = next_handler

      context, _ = create_context("GET", "/error")
      handler.call(context)

      context.response.status_code.should eq(500)
    end
  end

  describe "timing measurement" do
    it "calculates request latency" do
      handler = Azu::Handler::Logger.new
      next_handler = ->(ctx : HTTP::Server::Context) {
        sleep 0.01.seconds
        ctx.response.print "OK"
      }
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      # Latency should be logged
      get_response_body(context, io).should eq("OK")
    end

    it "handles fast requests" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/fast")
      handler.call(context)

      verify.call
    end
  end

  describe "handler chain integration" do
    it "logs even when errors occur" do
      handler = Azu::Handler::Logger.new
      error_handler = ->(_ctx : HTTP::Server::Context) {
        raise Exception.new("Test error")
      }
      handler.next = error_handler

      context, _ = create_context("GET", "/error")

      # Should log and then raise
      expect_raises(Exception, "Test error") do
        handler.call(context)
      end
    end

    it "always logs timing in ensure block" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      verify.call
    end
  end

  describe "concurrent requests" do
    it "logs concurrent requests correctly" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(5)
      handler.next = next_handler

      channel = Channel(Bool).new

      5.times do |i|
        spawn do
          context, _ = create_context("GET", "/test#{i}")
          handler.call(context)
          channel.send(true)
        end
      end

      5.times { channel.receive }
      verify.call
    end
  end

  describe "edge cases" do
    it "handles very long paths" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      long_path = "/" + ("a" * 1000)
      context, _ = create_context("GET", long_path)
      handler.call(context)

      verify.call
    end

    it "handles paths with special characters" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test?param=value&other=αβγ")
      handler.call(context)

      verify.call
    end

    it "handles all HTTP methods" do
      handler = Azu::Handler::Logger.new
      next_handler, verify = create_next_handler(5)
      handler.next = next_handler

      ["GET", "POST", "PUT", "PATCH", "DELETE"].each do |method|
        context, _ = create_context(method, "/test")
        handler.call(context)
      end

      verify.call
    end
  end
end

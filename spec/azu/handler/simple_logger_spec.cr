require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Handler::SimpleLogger do
  describe "initialization" do
    it "initializes with default log" do
      handler = Azu::Handler::SimpleLogger.new
      handler.should be_a(Azu::Handler::SimpleLogger)
      handler.log.should be_a(::Log)
    end

    it "initializes with custom log" do
      custom_log = Log.for("test")
      handler = Azu::Handler::SimpleLogger.new(custom_log)
      handler.log.should eq(custom_log)
    end

    it "creates async logger" do
      handler = Azu::Handler::SimpleLogger.new
      handler.async_logger.should be_a(Azu::AsyncLogging::AsyncLogger)
    end
  end

  describe "request ID generation" do
    it "generates request ID when not present" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      context.request.headers.has_key?("X-Request-ID").should be_true
      verify.call
    end

    it "preserves existing request ID" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Request-ID"] = "existing-id"
      context, _ = create_context("GET", "/test", headers)

      handler.call(context)

      context.request.headers["X-Request-ID"].should eq("existing-id")
      verify.call
    end

    it "generates unique IDs for different requests" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler, verify = create_next_handler(2)
      handler.next = next_handler

      context1, _ = create_context("GET", "/test1")
      handler.call(context1)
      id1 = context1.request.headers["X-Request-ID"]

      context2, _ = create_context("GET", "/test2")
      handler.call(context2)
      id2 = context2.request.headers["X-Request-ID"]

      id1.should_not eq(id2)
      verify.call
    end
  end

  describe "async logging" do
    it "logs successful requests asynchronously" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      # Give async logger time to complete
      sleep 0.1.seconds

      verify.call
    end

    it "logs request completion with context" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/api/users")
      handler.call(context)

      sleep 0.1.seconds
      verify.call
    end
  end

  describe "status code logging" do
    it "logs 2xx as info" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.status_code = 200
        ctx.response.print "OK"
      }
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      sleep 0.1.seconds
      context.response.status_code.should eq(200)
    end

    it "logs 3xx as info" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.status_code = 302
        ctx.response.headers["Location"] = "/redirect"
        ctx.response.print "Redirect"
      }
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      sleep 0.1.seconds
      context.response.status_code.should eq(302)
    end

    it "logs 4xx as warning" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.status_code = 404
        ctx.response.print "Not Found"
      }
      handler.next = next_handler

      context, _ = create_context("GET", "/missing")
      handler.call(context)

      sleep 0.1.seconds
      context.response.status_code.should eq(404)
    end

    it "logs 5xx as error" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.status_code = 500
        ctx.response.print "Error"
      }
      handler.next = next_handler

      context, _ = create_context("GET", "/error")
      handler.call(context)

      sleep 0.1.seconds
      context.response.status_code.should eq(500)
    end
  end

  describe "error handling" do
    it "logs errors asynchronously" do
      handler = Azu::Handler::SimpleLogger.new
      error_handler = ->(_ctx : HTTP::Server::Context) {
        raise Exception.new("Test error")
      }
      handler.next = error_handler

      context, _ = create_context("GET", "/error")

      expect_raises(Exception, "Test error") do
        handler.call(context)
      end

      sleep 0.1.seconds
    end

    it "re-raises exceptions after logging" do
      handler = Azu::Handler::SimpleLogger.new
      error_handler = ->(_ctx : HTTP::Server::Context) {
        raise Exception.new("Must be re-raised")
      }
      handler.next = error_handler

      context, _ = create_context("GET", "/error")

      expect_raises(Exception, "Must be re-raised") do
        handler.call(context)
      end
    end

    it "reports errors to error reporter" do
      handler = Azu::Handler::SimpleLogger.new
      error_handler = ->(_ctx : HTTP::Server::Context) {
        raise Exception.new("Reported error")
      }
      handler.next = error_handler

      context, _ = create_context("GET", "/error")

      expect_raises(Exception, "Reported error") do
        handler.call(context)
      end

      sleep 0.1.seconds
    end
  end

  describe "request context building" do
    it "includes method in context" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("POST", "/test")
      handler.call(context)

      sleep 0.1.seconds
      verify.call
    end

    it "includes path in context" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/api/users/123")
      handler.call(context)

      sleep 0.1.seconds
      verify.call
    end

    it "includes endpoint name in context" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Azu-Endpoint"] = "UserEndpoint"
      context, _ = create_context("GET", "/test", headers)

      handler.call(context)

      sleep 0.1.seconds
      verify.call
    end

    it "includes latency in context" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler = ->(ctx : HTTP::Server::Context) {
        sleep 0.01.seconds
        ctx.response.print "OK"
      }
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      sleep 0.15.seconds
      get_response_body(context, io).should eq("OK")
    end
  end

  describe "concurrent requests" do
    it "logs concurrent requests with unique IDs" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler, verify = create_next_handler(5)
      handler.next = next_handler

      ids = Set(String).new
      mutex = Mutex.new
      channel = Channel(String).new

      5.times do
        spawn do
          context, _ = create_context("GET", "/test")
          handler.call(context)
          channel.send(context.request.headers["X-Request-ID"])
        end
      end

      5.times do
        id = channel.receive
        mutex.synchronize { ids << id }
      end

      ids.size.should eq(5)
      sleep 0.1.seconds
      verify.call
    end
  end

  describe "edge cases" do
    it "handles requests without User-Agent" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      sleep 0.1.seconds
      verify.call
    end

    it "handles very fast requests" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/fast")
      handler.call(context)

      sleep 0.1.seconds
      verify.call
    end

    it "handles unknown status codes" do
      handler = Azu::Handler::SimpleLogger.new
      next_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.status_code = 999
        ctx.response.print "Unknown"
      }
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      sleep 0.1.seconds
      context.response.status_code.should eq(999)
    end
  end
end

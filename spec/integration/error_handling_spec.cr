require "../spec_helper"
require "../support/integration_helpers"

include IntegrationHelpers

describe "Error Handling Integration" do
  describe "Rescuer + RequestID integration" do
    it "includes request ID in error responses" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Exception.new("Test error")
      }

      rescuer.next = error_handler
      request_id.next = rescuer

      context, io = create_context("GET", "/test")
      request_id.call(context)

      context.response.status_code.should eq(500)
      request_id_value = context.request.headers["X-Request-ID"]
      request_id_value.should_not be_empty

      # Request ID should be available in response headers
      context.response.headers["X-Request-ID"].should eq(request_id_value)
    end

    it "generates request ID for errors without existing ID" do
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Exception.new("Error without ID")
      }

      rescuer.next = error_handler

      context, io = create_context("GET", "/test")
      rescuer.call(context)

      context.response.status_code.should eq(500)
      # Should have generated a request ID
      context.response.headers.has_key?("X-Error-ID").should be_true
    end
  end

  describe "Rescuer + Logger integration" do
    it "logs errors through logger" do
      rescuer = Azu::Handler::Rescuer.new
      logger = Azu::Handler::Logger.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Exception.new("Logged error")
      }

      logger.next = error_handler
      rescuer.next = logger

      context, io = create_context("GET", "/test")
      rescuer.call(context)

      context.response.status_code.should eq(500)
    end

    it "measures timing even when errors occur" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new
      logger = Azu::Handler::Logger.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        sleep 0.01.seconds
        raise Exception.new("Timed error")
      }

      logger.next = error_handler
      rescuer.next = logger
      request_id.next = rescuer

      context, io = create_context("GET", "/test")
      request_id.call(context)

      context.response.status_code.should eq(500)
      # Timing should be logged even for errors
    end
  end

  describe "custom error responses" do
    it "handles Response::Error with custom status codes" do
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Azu::Response::Error.new("Not found", HTTP::Status::NOT_FOUND, [] of String)
      }

      rescuer.next = error_handler

      context, io = create_context("GET", "/missing")
      rescuer.call(context)

      context.response.status_code.should eq(404)
      context.response.headers.has_key?("X-Error-ID").should be_true
      context.response.headers.has_key?("X-Error-Fingerprint").should be_true
    end

    it "handles validation errors" do
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Azu::Response::Error.new("Validation failed", HTTP::Status::UNPROCESSABLE_ENTITY, [] of String)
      }

      rescuer.next = error_handler

      context, io = create_context("POST", "/api/users")
      rescuer.call(context)

      context.response.status_code.should eq(422)
      context.response.headers.has_key?("X-Error-ID").should be_true
    end

    it "handles unauthorized errors" do
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Azu::Response::Error.new("Unauthorized", HTTP::Status::UNAUTHORIZED, [] of String)
      }

      rescuer.next = error_handler

      context, io = create_context("GET", "/admin")
      rescuer.call(context)

      context.response.status_code.should eq(401)
      context.response.headers.has_key?("X-Error-ID").should be_true
    end
  end

  describe "error context propagation" do
    it "includes request method in error context" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Exception.new("Error with method")
      }

      rescuer.next = error_handler
      request_id.next = rescuer

      context, io = create_context("POST", "/api/users")
      request_id.call(context)

      context.response.status_code.should eq(500)
      context.response.headers.has_key?("X-Error-ID").should be_true
    end

    it "includes request path in error context" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Exception.new("Error with path")
      }

      rescuer.next = error_handler
      request_id.next = rescuer

      context, io = create_context("GET", "/api/users/123")
      request_id.call(context)

      context.response.status_code.should eq(500)
      context.response.headers.has_key?("X-Error-ID").should be_true
    end
  end

  describe "nested exception handling" do
    it "handles exceptions with causes" do
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        begin
          raise Exception.new("Inner exception")
        rescue inner
          raise Exception.new("Outer exception", cause: inner)
        end
      }

      rescuer.next = error_handler

      context, io = create_context("GET", "/test")
      rescuer.call(context)

      context.response.status_code.should eq(500)
      context.response.headers.has_key?("X-Error-ID").should be_true
    end
  end

  describe "error recovery strategies" do
    it "allows graceful degradation" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new
      cors = Azu::Handler::CORS.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Exception.new("Service error")
      }

      cors.next = error_handler
      rescuer.next = cors
      request_id.next = rescuer

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, io = create_context("GET", "/test", headers)

      request_id.call(context)

      context.response.status_code.should eq(500)
      # CORS headers should still be set
      context.response.headers.has_key?("X-Request-ID").should be_true
    end
  end

  describe "concurrent error handling" do
    it "handles concurrent errors safely" do
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Exception.new("Concurrent error")
      }

      rescuer.next = error_handler

      channel = Channel(Int32).new

      10.times do
        spawn do
          context, io = create_context("GET", "/test")
          rescuer.call(context)
          channel.send(context.response.status_code)
        end
      end

      10.times do
        status = channel.receive
        status.should eq(500)
      end
    end
  end

  describe "error formats" do
    it "generates HTML error pages for browsers" do
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Exception.new("HTML error")
      }

      rescuer.next = error_handler

      context, io = create_context("GET", "/test")
      rescuer.call(context)

      context.response.headers.has_key?("Content-Type").should be_true
      context.response.headers.has_key?("X-Error-ID").should be_true
    end
  end

  describe "client error handling" do
    it "handles HTTP::Server::ClientError gracefully" do
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise HTTP::Server::ClientError.new("Bad request")
      }

      rescuer.next = error_handler

      context, io = create_context("GET", "/test")
      rescuer.call(context)

      # Client errors should not generate response
      io.rewind
      response = io.gets_to_end
      response.should_not contain("Bad request")
    end
  end

  describe "performance monitoring with errors" do
    it "records error metrics" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(ctx : HTTP::Server::Context) {
        raise Azu::Response::Error.new("Monitored error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)
      }

      rescuer.next = error_handler
      performance.next = rescuer

      context, io = create_context("GET", "/test")
      performance.call(context)

      stats = performance.stats
      stats.total_requests.should eq(1)
      stats.error_requests.should eq(1)
      stats.error_rate.should eq(100.0)
    end
  end
end


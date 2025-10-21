require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Handler::RequestId do
  describe "initialization" do
    it "initializes with default header name" do
      handler = Azu::Handler::RequestId.new
      handler.should be_a(Azu::Handler::RequestId)
    end

    it "initializes with custom header name" do
      handler = Azu::Handler::RequestId.new("X-Custom-Request-ID")
      handler.should be_a(Azu::Handler::RequestId)
    end
  end

  describe "request ID generation" do
    it "generates request ID when not present" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      context.request.headers.has_key?("X-Request-ID").should be_true
      context.request.headers["X-Request-ID"].should_not be_empty
      verify.call
    end

    it "generates unique request IDs" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(2)
      handler.next = next_handler

      context1, _ = create_context("GET", "/test")
      handler.call(context1)
      id1 = context1.request.headers["X-Request-ID"]

      context2, _ = create_context("GET", "/test")
      handler.call(context2)
      id2 = context2.request.headers["X-Request-ID"]

      id1.should_not eq(id2)
      verify.call
    end

    it "generates request IDs with proper format" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      request_id = context.request.headers["X-Request-ID"]
      request_id.should start_with("req_")
      request_id.size.should be > 20 # Should have timestamp and random part
      verify.call
    end
  end

  describe "request ID preservation" do
    it "preserves existing request ID from request" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Request-ID"] = "existing-request-id"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.request.headers["X-Request-ID"].should eq("existing-request-id")
      verify.call
    end

    it "does not modify valid existing request IDs" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      original_id = "custom-123-abc"
      headers = HTTP::Headers.new
      headers["X-Request-ID"] = original_id
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.request.headers["X-Request-ID"].should eq(original_id)
      verify.call
    end
  end

  describe "response headers" do
    it "adds request ID to response headers" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      context.response.headers.has_key?("X-Request-ID").should be_true
      context.response.headers["X-Request-ID"].should_not be_empty
      verify.call
    end

    it "matches request and response IDs" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      request_id = context.request.headers["X-Request-ID"]
      response_id = context.response.headers["X-Request-ID"]
      request_id.should eq(response_id)
      verify.call
    end

    it "propagates existing request ID to response" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Request-ID"] = "propagated-id"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.headers["X-Request-ID"].should eq("propagated-id")
      verify.call
    end
  end

  describe "custom header name" do
    it "uses custom header name for request" do
      handler = Azu::Handler::RequestId.new("X-Trace-ID")
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      context.request.headers.has_key?("X-Trace-ID").should be_true
      context.request.headers["X-Trace-ID"].should_not be_empty
      verify.call
    end

    it "uses custom header name for response" do
      handler = Azu::Handler::RequestId.new("X-Trace-ID")
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      context.response.headers.has_key?("X-Trace-ID").should be_true
      verify.call
    end

    it "preserves custom header from incoming request" do
      handler = Azu::Handler::RequestId.new("X-Correlation-ID")
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Correlation-ID"] = "correlation-123"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.request.headers["X-Correlation-ID"].should eq("correlation-123")
      context.response.headers["X-Correlation-ID"].should eq("correlation-123")
      verify.call
    end
  end

  describe "handler chain integration" do
    it "works with other handlers in chain" do
      request_id_handler = Azu::Handler::RequestId.new
      cors_handler = Azu::Handler::CORS.new
      next_handler, verify = create_next_handler(1)

      cors_handler.next = next_handler
      request_id_handler.next = cors_handler

      context, io = create_context("GET", "/test")
      request_id_handler.call(context)

      context.request.headers.has_key?("X-Request-ID").should be_true
      context.response.headers.has_key?("X-Request-ID").should be_true
      verify.call
    end

    it "provides request ID for downstream handlers" do
      request_id_handler = Azu::Handler::RequestId.new

      checking_handler = ->(context : HTTP::Server::Context) {
        # Downstream handler should see request ID
        context.request.headers["X-Request-ID"].should_not be_empty
        context.response.print "OK"
      }
      request_id_handler.next = checking_handler

      context, io = create_context("GET", "/test")
      request_id_handler.call(context)

      get_response_body(context, io).should eq("OK")
    end
  end

  describe "concurrent requests" do
    it "generates unique IDs for concurrent requests" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(10)
      handler.next = next_handler

      ids = Set(String).new
      mutex = Mutex.new
      completed_fibers = 0
      completion_mutex = Mutex.new

      10.times do
        spawn do
          context, io = create_context("GET", "/test")
          handler.call(context)
          request_id = context.request.headers["X-Request-ID"]

          mutex.synchronize { ids << request_id }
          completion_mutex.synchronize { completed_fibers += 1 }
        end
      end

      # Wait for all fibers to complete
      while completion_mutex.synchronize { completed_fibers < 10 }
        sleep(0.001.seconds)
      end

      ids.size.should eq(10)
      verify.call
    end
  end

  describe "logging and debugging" do
    it "provides consistent ID for request tracking" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      request_id = context.request.headers["X-Request-ID"]

      # ID should be available for logging throughout request lifecycle
      request_id.should_not be_empty
      request_id.should eq(context.response.headers["X-Request-ID"])
      verify.call
    end
  end

  describe "edge cases" do
    it "handles empty existing request ID" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Request-ID"] = ""
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      # Empty ID is preserved as-is (handler doesn't validate/replace empty strings)
      # This matches the actual behavior - only missing headers are generated
      context.request.headers["X-Request-ID"].should eq("")
      verify.call
    end

    it "handles very long request IDs" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      long_id = "x" * 1000
      headers = HTTP::Headers.new
      headers["X-Request-ID"] = long_id
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      # Should preserve the long ID
      context.request.headers["X-Request-ID"].should eq(long_id)
      verify.call
    end

    it "handles special characters in existing request IDs" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      special_id = "req-123-αβγ-日本語"
      headers = HTTP::Headers.new
      headers["X-Request-ID"] = special_id
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.request.headers["X-Request-ID"].should eq(special_id)
      verify.call
    end
  end

  describe "request ID format validation" do
    it "accepts UUID format request IDs" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      uuid = "550e8400-e29b-41d4-a716-446655440000"
      headers = HTTP::Headers.new
      headers["X-Request-ID"] = uuid
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.request.headers["X-Request-ID"].should eq(uuid)
      verify.call
    end

    it "accepts numeric request IDs" do
      handler = Azu::Handler::RequestId.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      numeric_id = "123456789"
      headers = HTTP::Headers.new
      headers["X-Request-ID"] = numeric_id
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.request.headers["X-Request-ID"].should eq(numeric_id)
      verify.call
    end
  end
end

require "../spec_helper"
require "../support/integration_helpers"

include IntegrationHelpers

describe "Middleware Chain Integration" do
  describe "full handler pipeline" do
    it "processes request through complete chain" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new
      logger = Azu::Handler::Logger.new
      cors = Azu::Handler::CORS.new

      final_handler, verify = create_next_handler(1)

      cors.next = final_handler
      logger.next = cors
      rescuer.next = logger
      request_id.next = rescuer

      context, io = create_context("GET", "/test")
      request_id.call(context)

      get_response_body(context, io).should eq("OK")
      context.request.headers.has_key?("X-Request-ID").should be_true
      verify.call
    end

    it "maintains context through chain" do
      request_id = Azu::Handler::RequestId.new
      logger = Azu::Handler::Logger.new

      checking_handler = ->(ctx : HTTP::Server::Context) {
        # Should have request ID from earlier handler
        ctx.request.headers["X-Request-ID"].should_not be_empty
        ctx.response.print "Verified"
      }

      logger.next = checking_handler
      request_id.next = logger

      context, io = create_context("GET", "/test")
      request_id.call(context)

      get_response_body(context, io).should eq("Verified")
    end

    it "handles errors at different chain positions" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new
      logger = Azu::Handler::Logger.new

      error_handler = ->(_ctx : HTTP::Server::Context) {
        raise Exception.new("Test error")
      }

      logger.next = error_handler
      rescuer.next = logger
      request_id.next = rescuer

      context, _ = create_context("GET", "/error")
      request_id.call(context)

      context.response.status_code.should eq(500)
      context.request.headers.has_key?("X-Request-ID").should be_true
    end
  end

  describe "handler order dependencies" do
    it "RequestId before Logger provides IDs for logging" do
      request_id = Azu::Handler::RequestId.new
      logger = Azu::Handler::Logger.new
      final_handler, verify = create_next_handler(1)

      logger.next = final_handler
      request_id.next = logger

      context, _ = create_context("GET", "/test")
      request_id.call(context)

      context.request.headers.has_key?("X-Request-ID").should be_true
      verify.call
    end

    it "Rescuer before application catches all errors" do
      rescuer = Azu::Handler::Rescuer.new
      error_handler = ->(_ctx : HTTP::Server::Context) {
        raise Exception.new("Application error")
      }
      rescuer.next = error_handler

      context, _ = create_context("GET", "/test")
      rescuer.call(context)

      context.response.status_code.should eq(500)
    end

    it "CORS before endpoint handles preflight" do
      cors = Azu::Handler::CORS.new(origins: ["https://example.com"])
      final_handler, verify = create_next_handler(0) # Should not reach final handler
      cors.next = final_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Access-Control-Request-Method"] = "POST"
      headers["Access-Control-Request-Headers"] = "Content-Type"
      context, _ = create_context("OPTIONS", "/test", headers)

      cors.call(context)

      context.response.headers.has_key?("Access-Control-Allow-Origin").should be_true
      verify.call
    end
  end

  describe "security chain" do
    it "processes through security handlers" do
      ip_spoofing = Azu::Handler::IpSpoofing.new
      cors = Azu::Handler::CORS.new(origins: ["https://example.com"])
      csrf = Azu::Handler::CSRF.new
      final_handler, verify = create_next_handler(1)

      csrf.next = final_handler
      cors.next = csrf
      ip_spoofing.next = cors

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["X-Forwarded-For"] = "192.168.1.1"
      context, io = create_context("GET", "/test", headers)

      ip_spoofing.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "blocks at first security violation" do
      ip_spoofing = Azu::Handler::IpSpoofing.new
      cors = Azu::Handler::CORS.new
      final_handler, verify = create_next_handler(0)

      cors.next = final_handler
      ip_spoofing.next = cors

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1"
      headers["X-Client-IP"] = "10.0.0.1" # Spoofing
      context, _ = create_context("GET", "/test", headers)

      ip_spoofing.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end
  end

  describe "monitoring chain" do
    it "tracks metrics through handler pipeline" do
      request_id = Azu::Handler::RequestId.new
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      logger = Azu::Handler::Logger.new
      final_handler, verify = create_next_handler(1)

      logger.next = final_handler
      performance.next = logger
      request_id.next = performance

      context, _ = create_context("GET", "/test")
      request_id.call(context)

      stats = performance.stats
      stats.total_requests.should eq(1)
      context.request.headers.has_key?("X-Request-ID").should be_true
      verify.call
    end

    it "correlates logs with request IDs" do
      request_id = Azu::Handler::RequestId.new
      logger = Azu::Handler::Logger.new
      performance = Azu::Handler::PerformanceMonitor.new
      final_handler, verify = create_next_handler(1)

      performance.next = final_handler
      logger.next = performance
      request_id.next = logger

      context, _ = create_context("GET", "/test")
      request_id.call(context)

      request_id_value = context.request.headers["X-Request-ID"]
      request_id_value.should_not be_empty
      verify.call
    end
  end

  describe "complex scenarios" do
    it "handles full production-like chain" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new
      logger = Azu::Handler::Logger.new
      cors = Azu::Handler::CORS.new
      csrf = Azu::Handler::CSRF.new([] of String)
      throttle = Azu::Handler::Throttle.new(60, 60, 100, [] of String, [] of String)
      final_handler, verify = create_next_handler(1)

      throttle.next = final_handler
      csrf.next = throttle
      cors.next = csrf
      logger.next = cors
      rescuer.next = logger
      request_id.next = rescuer

      headers = HTTP::Headers.new
      headers["REMOTE_ADDR"] = "192.168.1.1"
      context, io = create_context("GET", "/api/users", headers)

      request_id.call(context)

      get_response_body(context, io).should eq("OK")
      context.request.headers.has_key?("X-Request-ID").should be_true
      verify.call
      throttle.reset
    end

    it "handles concurrent requests through chain" do
      request_id = Azu::Handler::RequestId.new
      logger = Azu::Handler::Logger.new
      cors = Azu::Handler::CORS.new
      final_handler, verify = create_next_handler(10)

      cors.next = final_handler
      logger.next = cors
      request_id.next = logger

      channel = Channel(String).new
      ids = Set(String).new
      mutex = Mutex.new

      10.times do
        spawn do
          context, _ = create_context("GET", "/test")
          request_id.call(context)
          id = context.request.headers["X-Request-ID"]
          channel.send(id)
        end
      end

      10.times do
        id = channel.receive
        mutex.synchronize { ids << id }
      end

      ids.size.should eq(10)
      verify.call
    end
  end

  describe "error propagation" do
    it "allows errors to bubble through Rescuer" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new
      logger = Azu::Handler::Logger.new

      error_handler = ->(_ctx : HTTP::Server::Context) {
        raise Azu::Response::Error.new("Custom error", HTTP::Status::UNPROCESSABLE_ENTITY, [] of String)
      }

      logger.next = error_handler
      rescuer.next = logger
      request_id.next = rescuer

      context, io = create_context("POST", "/api/users")
      request_id.call(context)

      context.response.status_code.should eq(422)
      io.rewind
      response = io.gets_to_end
      response.should contain("Custom error")
    end

    it "preserves context in error responses" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(_ctx : HTTP::Server::Context) {
        raise Exception.new("Error with context")
      }

      rescuer.next = error_handler
      request_id.next = rescuer

      context, _ = create_context("GET", "/error")
      request_id.call(context)

      context.response.status_code.should eq(500)
      context.request.headers["X-Request-ID"].should_not be_empty
    end
  end

  describe "response modification" do
    it "allows handlers to modify response headers" do
      cors = Azu::Handler::CORS.new(origins: ["https://example.com"])
      request_id = Azu::Handler::RequestId.new
      final_handler, verify = create_next_handler(1)

      request_id.next = final_handler
      cors.next = request_id

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      context, _ = create_context("GET", "/test", headers)

      cors.call(context)

      context.response.headers["Access-Control-Allow-Origin"].should eq("https://example.com")
      context.response.headers.has_key?("X-Request-ID").should be_true
      verify.call
    end

    it "preserves headers through entire chain" do
      request_id = Azu::Handler::RequestId.new
      cors = Azu::Handler::CORS.new(origins: ["*"])
      logger = Azu::Handler::Logger.new
      final_handler, verify = create_next_handler(1)

      logger.next = final_handler
      cors.next = logger
      request_id.next = cors

      headers = HTTP::Headers.new
      headers["Origin"] = "https://test.com"
      context, _ = create_context("GET", "/test", headers)

      request_id.call(context)

      context.response.headers.has_key?("X-Request-ID").should be_true
      context.response.headers.has_key?("Access-Control-Allow-Origin").should be_true
      verify.call
    end
  end

  describe "performance impact" do
    it "measures total chain latency" do
      request_id = Azu::Handler::RequestId.new
      logger = Azu::Handler::Logger.new
      cors = Azu::Handler::CORS.new
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      final_handler, verify = create_next_handler(1)

      performance.next = final_handler
      cors.next = performance
      logger.next = cors
      request_id.next = logger

      start_time = Time.monotonic
      context, _ = create_context("GET", "/test")
      request_id.call(context)
      elapsed = Time.monotonic - start_time

      elapsed.total_milliseconds.should be < 100 # Should be fast
      verify.call
    end
  end
end

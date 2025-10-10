require "../spec_helper"
require "../support/integration_helpers"

include IntegrationHelpers

describe "Performance Integration" do
  describe "PerformanceMonitor + handler chain" do
    it "tracks metrics through entire chain" do
      request_id = Azu::Handler::RequestId.new
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      logger = Azu::Handler::Logger.new
      cors = Azu::Handler::CORS.new
      final_handler, verify = create_next_handler(1)

      cors.next = final_handler
      logger.next = cors
      performance.next = logger
      request_id.next = performance

      context, io = create_context("GET", "/test")
      request_id.call(context)

      stats = performance.stats
      stats.total_requests.should eq(1)
      stats.avg_response_time.should be > 0
      verify.call
    end

    it "tracks endpoint-specific metrics" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      final_handler, verify = create_next_handler(3)
      performance.next = final_handler

      headers1 = HTTP::Headers.new
      headers1["X-Azu-Endpoint"] = "UsersEndpoint"
      context1, io1 = create_context("GET", "/users", headers1)
      performance.call(context1)

      headers2 = HTTP::Headers.new
      headers2["X-Azu-Endpoint"] = "PostsEndpoint"
      context2, io2 = create_context("GET", "/posts", headers2)
      performance.call(context2)
      performance.call(context2)

      users_stats = performance.endpoint_stats("UsersEndpoint")
      posts_stats = performance.endpoint_stats("PostsEndpoint")

      users_stats["total_requests"]?.should eq(1.0)
      posts_stats["total_requests"]?.should eq(2.0)
      verify.call
    end
  end

  describe "memory tracking" do
    it "tracks memory usage across requests" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      final_handler, verify = create_next_handler(5)
      performance.next = final_handler

      5.times do
        context, io = create_context("GET", "/test")
        performance.call(context)
      end

      stats = performance.stats
      stats.avg_memory_usage.should be >= 0
      stats.peak_memory_usage.should be >= stats.avg_memory_usage
      verify.call
    end
  end

  describe "slow request detection" do
    it "logs warnings for slow requests" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)

      slow_handler = ->(ctx : HTTP::Server::Context) {
        sleep 0.05.seconds  # Slow request
        ctx.response.print "Slow"
      }
      performance.next = slow_handler

      context, io = create_context("GET", "/slow")
      performance.call(context)

      get_response_body(context, io).should eq("Slow")
      # Warning should be logged
    end
  end

  describe "concurrent performance tracking" do
    it "safely tracks concurrent requests" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      final_handler, verify = create_next_handler(20)
      performance.next = final_handler

      channel = Channel(Bool).new

      20.times do
        spawn do
          context, io = create_context("GET", "/test")
          performance.call(context)
          channel.send(true)
        end
      end

      20.times { channel.receive }

      stats = performance.stats
      stats.total_requests.should eq(20)
      verify.call
    end
  end

  describe "error rate tracking" do
    it "calculates error rates correctly" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      rescuer = Azu::Handler::Rescuer.new

      mixed_handler = ->(ctx : HTTP::Server::Context) {
        if ctx.request.path == "/error"
          raise Azu::Response::Error.new("Error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)
        else
          ctx.response.print "OK"
        end
      }

      rescuer.next = mixed_handler
      performance.next = rescuer

      # 3 successful requests
      3.times do
        context, io = create_context("GET", "/ok")
        performance.call(context)
      end

      # 1 error request
      context, io = create_context("GET", "/error")
      performance.call(context)

      stats = performance.stats
      stats.total_requests.should eq(4)
      stats.error_requests.should eq(1)
      stats.error_rate.should eq(25.0)
    end
  end

  describe "percentile calculations" do
    it "calculates response time percentiles" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      final_handler, verify = create_next_handler(100)
      performance.next = final_handler

      100.times do
        context, io = create_context("GET", "/test")
        performance.call(context)
      end

      stats = performance.stats
      stats.p95_response_time.should be >= 0
      stats.p99_response_time.should be >= stats.p95_response_time
      stats.p99_response_time.should be <= stats.max_response_time
      verify.call
    end
  end

  describe "metrics clearing" do
    it "clears metrics on demand" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      final_handler, verify = create_next_handler(5)
      performance.next = final_handler

      5.times do
        context, io = create_context("GET", "/test")
        performance.call(context)
      end

      performance.clear_metrics

      stats = performance.stats
      stats.total_requests.should eq(0)
      verify.call
    end
  end

  describe "JSON export" do
    it "exports metrics as JSON" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      final_handler, verify = create_next_handler(3)
      performance.next = final_handler

      3.times do
        context, io = create_context("GET", "/test")
        performance.call(context)
      end

      json_io = IO::Memory.new
      performance.to_json(json_io)
      json_io.rewind
      json = json_io.gets_to_end

      json.should contain("total_requests")
      json.should contain("avg_response_time")
      verify.call
    end
  end

  describe "recent requests tracking" do
    it "tracks recent request history" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      final_handler, verify = create_next_handler(10)
      performance.next = final_handler

      10.times do |i|
        context, io = create_context("GET", "/test#{i}")
        performance.call(context)
      end

      recent = performance.recent_requests(5)
      recent.size.should be <= 5
      verify.call
    end
  end

  describe "performance with all handlers" do
    it "measures overhead of full handler chain" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new
      logger = Azu::Handler::Logger.new
      cors = Azu::Handler::CORS.new
      csrf = Azu::Handler::CSRF.new([] of String)
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)
      final_handler, verify = create_next_handler(1)

      performance.next = final_handler
      csrf.next = performance
      cors.next = csrf
      logger.next = cors
      rescuer.next = logger
      request_id.next = rescuer

      start_time = Time.monotonic
      context, io = create_context("GET", "/test")
      request_id.call(context)
      elapsed = Time.monotonic - start_time

      # Full chain should still be fast
      elapsed.total_milliseconds.should be < 100

      stats = performance.stats
      stats.total_requests.should eq(1)
      verify.call
    end
  end
end


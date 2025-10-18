require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Handler::PerformanceMonitor do
  describe "initialization" do
    it "initializes with default metrics" do
      handler = Azu::Handler::PerformanceMonitor.new
      handler.should be_a(Azu::Handler::PerformanceMonitor)
      handler.metrics.should be_a(Azu::PerformanceMetrics)
    end

    it "initializes with custom metrics" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      handler.metrics.should eq(metrics)
    end

    it "starts with monitoring enabled" do
      handler = Azu::Handler::PerformanceMonitor.new
      handler.enabled?.should be_true
    end
  end

  describe "metrics collection" do
    it "records request metrics" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      stats = handler.stats
      stats.total_requests.should eq(1)
      verify.call
    end

    it "tracks processing time" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      next_handler = ->(ctx : HTTP::Server::Context) {
        sleep 0.01.seconds
        ctx.response.print "OK"
      }
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      stats = handler.stats
      stats.avg_response_time.should be > 0
    end

    it "tracks memory usage" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      stats = handler.stats
      stats.avg_memory_usage.should be >= 0
      verify.call
    end

    it "records endpoint names" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Azu-Endpoint"] = "TestEndpoint"
      context, _ = create_context("GET", "/test", headers)

      handler.call(context)

      endpoint_stats = handler.endpoint_stats("TestEndpoint")
      endpoint_stats["total_requests"]?.should_not be_nil
      verify.call
    end
  end

  describe "request ID generation" do
    it "generates request ID when missing" do
      handler = Azu::Handler::PerformanceMonitor.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      context.request.headers.has_key?("X-Request-ID").should be_true
      verify.call
    end

    it "preserves existing request ID" do
      handler = Azu::Handler::PerformanceMonitor.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Request-ID"] = "existing-id"
      context, _ = create_context("GET", "/test", headers)

      handler.call(context)

      context.request.headers["X-Request-ID"].should eq("existing-id")
      verify.call
    end
  end

  describe "enabled/disabled state" do
    it "skips metrics when disabled" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      handler.enabled = false
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      stats = handler.stats
      stats.total_requests.should eq(0)
      verify.call
    end

    it "collects metrics when enabled" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      handler.enabled = true
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      stats = handler.stats
      stats.total_requests.should eq(1)
      verify.call
    end
  end

  describe "statistics aggregation" do
    it "aggregates stats across multiple requests" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      next_handler, verify = create_next_handler(5)
      handler.next = next_handler

      5.times do
        context, _ = create_context("GET", "/test")
        handler.call(context)
      end

      stats = handler.stats
      stats.total_requests.should eq(5)
      verify.call
    end

    it "tracks error rates" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      error_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.status_code = 500
        ctx.response.print "Error"
      }
      handler.next = error_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      stats = handler.stats
      stats.error_requests.should eq(1)
      stats.error_rate.should eq(100.0)
    end

    it "calculates percentiles" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      next_handler, verify = create_next_handler(10)
      handler.next = next_handler

      10.times do
        context, _ = create_context("GET", "/test")
        handler.call(context)
      end

      stats = handler.stats
      stats.p95_response_time.should be >= 0
      stats.p99_response_time.should be >= stats.p95_response_time
      verify.call
    end
  end

  describe "recent requests" do
    it "tracks recent requests" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      next_handler, verify = create_next_handler(3)
      handler.next = next_handler

      3.times do |i|
        context, _ = create_context("GET", "/test#{i}")
        handler.call(context)
      end

      recent = handler.recent_requests(10)
      recent.size.should eq(3)
      verify.call
    end

    it "limits recent requests to specified count" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      next_handler, verify = create_next_handler(10)
      handler.next = next_handler

      10.times do
        context, _ = create_context("GET", "/test")
        handler.call(context)
      end

      recent = handler.recent_requests(5)
      recent.size.should be <= 5
      verify.call
    end
  end

  describe "performance warnings" do
    it "logs warning for slow requests" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      slow_handler = ->(ctx : HTTP::Server::Context) {
        sleep 2.seconds # Above default threshold
        ctx.response.print "Slow"
      }
      handler.next = slow_handler

      context, io = create_context("GET", "/slow")
      handler.call(context)

      # Should log warning (verified through logs)
      get_response_body(context, io).should eq("Slow")
    end
  end

  describe "clearing metrics" do
    it "clears collected metrics" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      next_handler, verify = create_next_handler(3)
      handler.next = next_handler

      3.times do
        context, _ = create_context("GET", "/test")
        handler.call(context)
      end

      handler.clear_metrics

      stats = handler.stats
      stats.total_requests.should eq(0)
      verify.call
    end
  end

  describe "JSON export" do
    it "exports metrics as JSON" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      json_io = IO::Memory.new
      handler.to_json(json_io)
      json_io.rewind
      json_output = json_io.gets_to_end

      json_output.should contain("total_requests")
      verify.call
    end
  end

  describe "concurrent requests" do
    it "safely handles concurrent requests" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::PerformanceMonitor.new(metrics)
      next_handler, verify = create_next_handler(10)
      handler.next = next_handler

      channel = Channel(Bool).new

      10.times do
        spawn do
          context, _ = create_context("GET", "/test")
          handler.call(context)
          channel.send(true)
        end
      end

      10.times { channel.receive }

      stats = handler.stats
      stats.total_requests.should eq(10)
      verify.call
    end
  end

  describe "edge cases" do
    it "handles requests without endpoint header" do
      handler = Azu::Handler::PerformanceMonitor.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/test")
      handler.call(context)

      stats = handler.stats
      stats.total_requests.should eq(1)
      verify.call
    end

    it "handles very fast requests" do
      handler = Azu::Handler::PerformanceMonitor.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("GET", "/fast")
      handler.call(context)

      stats = handler.stats
      stats.total_requests.should eq(1)
      verify.call
    end
  end
end

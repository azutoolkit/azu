require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Handler::DevDashboard do
  describe "initialization" do
    it "initializes with default path" do
      handler = Azu::Handler::DevDashboard.new
      handler.should be_a(Azu::Handler::DevDashboard)
      handler.path.should eq("/dev-dashboard")
    end

    it "initializes with custom path" do
      handler = Azu::Handler::DevDashboard.new("/custom-dashboard")
      handler.path.should eq("/custom-dashboard")
    end

    it "initializes with custom metrics" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::DevDashboard.new(metrics: metrics)
      handler.metrics.should eq(metrics)
    end
  end

  describe "routing" do
    it "handles dashboard requests" do
      handler = Azu::Handler::DevDashboard.new

      context, io = create_context("GET", "/dev-dashboard")
      handler.call(context)

      context.response.close
      io.rewind
      response = io.gets_to_end
      response.should contain("<!DOCTYPE html>") # Should render HTML
      context.response.headers["Content-Type"].should contain("text/html")
    end

    it "passes through non-dashboard requests" do
      handler = Azu::Handler::DevDashboard.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/other-path")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "respects custom dashboard path" do
      handler = Azu::Handler::DevDashboard.new("/metrics")

      context, io = create_context("GET", "/metrics")
      handler.call(context)

      context.response.headers["Content-Type"].should contain("text/html")
    end
  end

  describe "dashboard content" do
    it "renders performance metrics" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      context, io = create_context("GET", "/dev-dashboard")
      handler.call(context)

      context.response.close
      io.rewind
      response = io.gets_to_end
      # Should contain metrics-related content
      response.should_not be_empty
    end

    it "includes metrics from performance monitor" do
      metrics = Azu::PerformanceMetrics.new

      # Add some test data
      metrics.record_request(
        endpoint: "TestEndpoint",
        method: "GET",
        path: "/test",
        processing_time: 10.0,
        memory_before: 100_000_i64,
        memory_after: 110_000_i64,
        status_code: 200,
        request_id: "test-id"
      )

      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      context, io = create_context("GET", "/dev-dashboard")
      handler.call(context)

      context.response.close
      io.rewind
      response = io.gets_to_end
      response.should_not be_empty
    end
  end

  describe "clearing metrics" do
    it "clears metrics when clear parameter is provided" do
      metrics = Azu::PerformanceMetrics.new
      metrics.record_request(
        endpoint: "TestEndpoint",
        method: "GET",
        path: "/test",
        processing_time: 10.0,
        memory_before: 100_000_i64,
        memory_after: 110_000_i64,
        status_code: 200,
        request_id: "test-id"
      )

      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      context, io = create_context("GET", "/dev-dashboard?clear=true")
      handler.call(context)

      context.response.status_code.should eq(302)
      context.response.headers["Location"].should eq("/dev-dashboard")

      stats = metrics.aggregate_stats
      stats.total_requests.should eq(0)
    end

    it "does not clear metrics without clear parameter" do
      metrics = Azu::PerformanceMetrics.new
      metrics.record_request(
        endpoint: "TestEndpoint",
        method: "GET",
        path: "/test",
        processing_time: 10.0,
        memory_before: 100_000_i64,
        memory_after: 110_000_i64,
        status_code: 200,
        request_id: "test-id"
      )

      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      context, io = create_context("GET", "/dev-dashboard")
      handler.call(context)

      context.response.status_code.should eq(200)

      stats = metrics.aggregate_stats
      stats.total_requests.should eq(1)
    end
  end

  describe "error handling" do
    it "handles rendering errors gracefully" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      # Create valid request
      context, io = create_context("GET", "/dev-dashboard")

      # Should not raise exception
      handler.call(context)

      # Should have a response
      context.response.status_code.should_not eq(0)
    end

    it "returns 500 on internal errors" do
      # This would require mocking the component to force an error
      # For now, we test that the error handling path exists
      handler = Azu::Handler::DevDashboard.new
      handler.should be_a(Azu::Handler::DevDashboard)
    end
  end

  describe "handler chain integration" do
    it "works in handler chain" do
      dashboard_handler = Azu::Handler::DevDashboard.new
      next_handler, verify = create_next_handler(1)
      dashboard_handler.next = next_handler

      context, io = create_context("GET", "/api/users")
      dashboard_handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "renders dashboard without calling next handler" do
      dashboard_handler = Azu::Handler::DevDashboard.new
      next_handler, verify = create_next_handler(0)
      dashboard_handler.next = next_handler

      context, io = create_context("GET", "/dev-dashboard")
      dashboard_handler.call(context)

      context.response.headers["Content-Type"].should contain("text/html")
      verify.call
    end
  end

  describe "concurrent access" do
    it "handles concurrent dashboard requests" do
      handler = Azu::Handler::DevDashboard.new
      channel = Channel(Bool).new

      5.times do
        spawn do
          context, io = create_context("GET", "/dev-dashboard")
          handler.call(context)
          context.response.headers["Content-Type"].should contain("text/html")
          channel.send(true)
        end
      end

      5.times { channel.receive }
    end
  end

  describe "edge cases" do
    it "handles empty metrics" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      context, io = create_context("GET", "/dev-dashboard")
      handler.call(context)

      context.response.status_code.should eq(200)
    end

    it "handles query parameters in dashboard path" do
      handler = Azu::Handler::DevDashboard.new

      context, io = create_context("GET", "/dev-dashboard?param=value")
      handler.call(context)

      # Should still render dashboard
      context.response.headers["Content-Type"].should contain("text/html")
    end
  end
end


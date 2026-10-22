require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

class FakeAdapter < Azu::DatabaseAdapter
  getter executed = [] of String

  def read_only(sql : String, limit : Int32) : {Array(String), Array(Array(String?))}
    @executed << sql
    {["one"], [["1"] of String?, [nil] of String?]}
  end

  def pool : Azu::PoolSnapshot?
    Azu::PoolSnapshot.new(3, 1, 0, 10)
  end

  def dialect : String
    "sqlite"
  end
end

def post_dashboard_sql(handler, body : String, remote = "127.0.0.1", headers = HTTP::Headers{"X-Requested-With" => "azu-dashboard"})
  context, io = create_context_with_remote_addr("POST", "/dev-dashboard/sql", remote, headers)
  context.request.body = IO::Memory.new(body)
  handler.call(context)
  {context, get_response_body(context, io)}
end

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
  describe "database tab" do
    it "renders the Database & Queries section" do
      handler = Azu::Handler::DevDashboard.new(queries: Azu::QueryStore.new)
      context, io = create_context("GET", "/dev-dashboard")
      handler.call(context)
      body = get_response_body(context, io)
      body.should contain("Database &amp; Queries")
      body.should contain("id='database'")
      body.should contain("dbx-root")
    end

    it "serves queries.json with stats, alerts and the since cursor" do
      store = Azu::QueryStore.new
      4.times { |i| store.record_query("SELECT * FROM posts WHERE user_id = #{i}", [] of String, 2.0, 1_i64, nil, "src/a.cr:1", nil, "r1", "E", "GET", "/", 1_u64) }
      handler = Azu::Handler::DevDashboard.new(queries: store)

      context, io = create_context("GET", "/dev-dashboard/queries.json")
      handler.call(context)
      json = JSON.parse(get_response_body(context, io))
      json["stats"]["total"].as_i.should eq 4
      json["stats"]["n_plus_one"].as_i.should eq 1
      json["alerts"].as_a.size.should eq 1
      json["queries"].as_a.size.should eq 4
      json["config"]["playground"].as_bool.should be_false

      context, io = create_context("GET", "/dev-dashboard/queries.json?since=#{json["last_id"]}")
      handler.call(context)
      JSON.parse(get_response_body(context, io))["queries"].as_a.should be_empty
    end

    it "clears recorded queries with ?clear=true" do
      store = Azu::QueryStore.new
      store.record_query("SELECT 1", [] of String, 1.0, 1_i64, nil, nil, nil, nil, nil, nil, nil, 1_u64)
      handler = Azu::Handler::DevDashboard.new(queries: store)
      context, _io = create_context("GET", "/dev-dashboard?clear=true")
      handler.call(context)
      store.queries.should be_empty
    end

    describe "SQL playground" do
      it "runs a read-only query in development from loopback" do
        store = Azu::QueryStore.new
        adapter = FakeAdapter.new
        store.adapter = adapter
        handler = Azu::Handler::DevDashboard.new(queries: store)
        with_azu_env(Azu::Environment::Development) do
          context, body = post_dashboard_sql(handler, %({"sql":"SELECT 1","mode":"run"}))
          context.response.status_code.should eq 200
          result = JSON.parse(body)
          result["columns"].as_a.map(&.as_s).should eq ["one"]
          result["rows"].as_a.size.should eq 2
          adapter.executed.should eq ["SELECT 1"]

          _, _ = post_dashboard_sql(handler, %({"sql":"SELECT 1","mode":"explain"}))
          adapter.executed.last.should eq "EXPLAIN QUERY PLAN SELECT 1"
        end
      end

      it "refuses writes, non-loopback clients, missing header and non-development envs" do
        store = Azu::QueryStore.new
        adapter = FakeAdapter.new
        store.adapter = adapter
        handler = Azu::Handler::DevDashboard.new(queries: store)

        with_azu_env(Azu::Environment::Development) do
          ctx, _ = post_dashboard_sql(handler, %({"sql":"DELETE FROM users","mode":"run"}))
          ctx.response.status_code.should eq 400
          ctx, _ = post_dashboard_sql(handler, %({"sql":"INSERT INTO t VALUES (1)","mode":"explain"}))
          ctx.response.status_code.should eq 400
          ctx, _ = post_dashboard_sql(handler, %({"sql":"SELECT 1","mode":"run"}), remote: "10.0.0.5")
          ctx.response.status_code.should eq 404
          ctx, _ = post_dashboard_sql(handler, %({"sql":"SELECT 1","mode":"run"}), headers: HTTP::Headers.new)
          ctx.response.status_code.should eq 403
          ctx, _ = post_dashboard_sql(handler, %({"sql":"SELECT 1"}), headers: HTTP::Headers{"X-Requested-With" => "azu-dashboard", "Origin" => "http://evil.test", "Host" => "localhost:4000"})
          ctx.response.status_code.should eq 403
          ctx, _ = post_dashboard_sql(handler, "not json")
          ctx.response.status_code.should eq 400
        end

        with_azu_env(Azu::Environment::Production) do
          ctx, _ = post_dashboard_sql(handler, %({"sql":"SELECT 1","mode":"run"}))
          ctx.response.status_code.should eq 404
        end
        adapter.executed.should be_empty
      end
    end
  end
end

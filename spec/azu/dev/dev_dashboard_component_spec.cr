require "../../spec_helper"
require "../../../src/azu/dev/dev"

alias DashboardProvider = Azu::Components::DashboardDataProvider
alias DashboardUI = Azu::Components::Dashboard

private def record_request(metrics, ms : Float64, status : Int32 = 200, endpoint = "Users::Index", method = "GET", path = "/users")
  metrics.record_request(endpoint, method, path, ms, 1_000_000_i64, 1_100_000_i64, status, "req-#{ms}")
end

private def provider_for(metrics : Azu::PerformanceMetrics, start_time : Time = Time.utc)
  DashboardProvider.new(metrics, start_time, Log.for("spec"))
end

describe Azu::Components::DevDashboardComponent do
  it "renders a complete document without the Component wrapper" do
    html = Azu::Components::DevDashboardComponent.new(Azu::PerformanceMetrics.new).render

    html.should start_with("<!DOCTYPE html>")
    html.should_not contain("data-spark-view")
  end

  it "measures uptime from the start time it is given" do
    html = Azu::Components::DevDashboardComponent.new(Azu::PerformanceMetrics.new, start_time: Time.utc - 2.hours - 5.minutes).render

    html.should contain("2h 5m")
  end

  it "draws the middleware pipeline in registration order" do
    config = Azu::Configuration.new
    config.handlers = [Azu::Handler::RequestId.new, Azu::Handler::Rescuer.new, Azu::Handler::DevDashboard.new] of HTTP::Handler

    Azu.with_config(config) do
      html = Azu::Components::DevDashboardComponent.new(Azu::PerformanceMetrics.new).render
      positions = %w[RequestId Rescuer DevDashboard].map { |name| html.index!("<strong>#{name}</strong>") }

      positions.should eq(positions.sort)
      html.should contain("azd-node is-self")
    end
  end

  it "says so when no pipeline was registered" do
    config = Azu::Configuration.new

    Azu.with_config(config) do
      Azu::Components::DevDashboardComponent.new(Azu::PerformanceMetrics.new).render.should contain("Pipeline not registered")
    end
  end

  it "warns when exposed outside development" do
    config = Azu::Configuration.new
    config.env = Azu::Environment::Production

    Azu.with_config(config) do
      Azu::Components::DevDashboardComponent.new(Azu::PerformanceMetrics.new).render.should contain("<div class='azd-banner'")
    end

    config.env = Azu::Environment::Development
    Azu.with_config(config) do
      Azu::Components::DevDashboardComponent.new(Azu::PerformanceMetrics.new).render.should_not contain("<div class='azd-banner'")
    end
  end

  it "keeps secrets and connection strings out of the Config tab" do
    config = Azu::Configuration.new
    config.ssl_key = "/secrets/private.key"
    config.ssl_cert = "/secrets/cert.pem"
    config.cache_config.redis_url = "redis://admin:hunter2@cache.internal:6379/0"

    Azu.with_config(config) do
      html = Azu::Components::DevDashboardComponent.new(Azu::PerformanceMetrics.new).render

      html.should contain("Hot reload (HMR)")
      ["/secrets/", "hunter2", "cache.internal"].each { |secret| html.should_not contain(secret) }
    end
  end

  it "shows explicit n/a states instead of invented numbers" do
    empty = Azu::Components::DevDashboardComponent.new(Azu::PerformanceMetrics.new).render
    empty.should contain("No requests recorded yet")
    empty.should contain("azd-kpi-value is-na")
    ["CPU", "Test Results", "Coverage"].each { |invented| empty.should_not contain(invented) }

    metrics = Azu::PerformanceMetrics.new
    record_request(metrics, 12.0)
    busy = Azu::Components::DevDashboardComponent.new(metrics).render
    busy.should_not contain("No requests recorded yet")
    busy.should contain(">p50<")
    busy.should contain(">p99<")
  end
end

describe Azu::Components::DashboardDataProvider do
  describe "#latency" do
    it "is nil until a request is recorded" do
      provider_for(Azu::PerformanceMetrics.new).latency.should be_nil
    end

    it "computes real percentiles from the request window" do
      metrics = Azu::PerformanceMetrics.new
      (1..100).each { |millis| record_request(metrics, millis.to_f) }

      latency = provider_for(metrics).latency || raise "expected latency percentiles"
      latency.p50.should eq(50.0)
      latency.p95.should eq(95.0)
      latency.p99.should eq(99.0)
      latency.avg.should eq(50.5)
    end
  end

  describe "#latency_histogram" do
    it "buckets requests by duration" do
      metrics = Azu::PerformanceMetrics.new
      [2.0, 5.0, 20.0, 150.0, 400.0, 2500.0].each { |millis| record_request(metrics, millis) }

      counts = provider_for(metrics).latency_histogram.map(&.count)
      counts.should eq([2, 1, 0, 1, 1, 1])
    end
  end

  describe "#slowest_requests and #endpoint_stats" do
    it "ranks by duration and groups by endpoint" do
      metrics = Azu::PerformanceMetrics.new
      record_request(metrics, 10.0, endpoint: "Fast")
      record_request(metrics, 900.0, endpoint: "Slow")
      record_request(metrics, 700.0, 500, endpoint: "Slow")

      provider = provider_for(metrics)
      provider.slowest_requests(2).map(&.processing_time).should eq([900.0, 700.0])

      stats = provider.endpoint_stats
      stats.map(&.name).should eq(["Slow", "Fast"])
      stats.first.error_rate.should eq(50.0)
    end
  end

  describe "#log_entries" do
    it "derives verbosity from status, latency and cache errors, newest first" do
      metrics = Azu::PerformanceMetrics.new
      record_request(metrics, 5.0, 200)
      record_request(metrics, 5.0, 404)
      record_request(metrics, 5.0, 503)
      record_request(metrics, 1500.0, 200)
      metrics.record_cache("k", "get", "memory", 1.0, true)
      metrics.record_cache("k", "get", "redis", 1.0, nil, error: "boom")
      metrics.record_component("c1", "Counter", "mount")

      entries = provider_for(metrics).log_entries
      entries.size.should eq(7)
      times = entries.map(&.time)
      times.should eq(times.dup.sort!.reverse!)

      by_level = entries.group_by(&.level).transform_values(&.size)
      by_level[DashboardUI::Level::Error].should eq(2) # 503 and the failing cache call
      by_level[DashboardUI::Level::Warn].should eq(2)  # 404 and the 1.5 s request
      by_level[DashboardUI::Level::Info].should eq(1)
      by_level[DashboardUI::Level::Debug].should eq(2) # good cache call and component event
    end

    it "renders an entry as copyable plain text" do
      metrics = Azu::PerformanceMetrics.new
      record_request(metrics, 12.5, 500, path: "/boom")

      text = provider_for(metrics).log_entries.first.to_text
      text.should contain("ERROR GET /boom 500 12.5ms")
      text.should contain("Request ID: req-12.5")
    end
  end

  describe "#health_score and #insights" do
    # The score includes database findings from the process-wide query store and, with cql loaded
    # (the whole suite compiles it in), from its monitor; earlier specs may have filled either.
    cql_monitor = nil

    before_each do
      Azu::QueryStore.instance.clear
      {% if @top_level.has_constant?("CQL") %}
        cql_monitor ||= CQL::Performance.monitor
        CQL::Performance.monitor = CQL::Performance::Monitor.new(CQL::Performance::Config.new { |config| config.monitoring.enabled = false })
      {% end %}
    end

    after_all do
      {% if @top_level.has_constant?("CQL") %}
        cql_monitor.try { |monitor| CQL::Performance.monitor = monitor }
      {% end %}
    end

    it "is perfect for an idle app and does not penalise an unused cache" do
      metrics = Azu::PerformanceMetrics.new
      metrics.record_cache("k", "set", "memory", 1.0)

      provider = provider_for(metrics)
      provider.health_score.should eq(100)
      provider.insights.should be_empty
    end

    it "orders insights by severity" do
      metrics = Azu::PerformanceMetrics.new
      10.times { record_request(metrics, 600.0, 500) }

      insights = provider_for(metrics).insights
      insights.first.status.should eq(DashboardUI::Status::Bad)
      insights.first.message.should eq("High error rate detected")
      statuses = insights.map(&.status)
      statuses.should eq(statuses.dup.sort!.reverse!)
    end
  end

  describe "#rss_bytes and #uptime" do
    it "reports a plausible resident set size where the OS exposes one" do
      rss = provider_for(Azu::PerformanceMetrics.new).rss_bytes
      {% if flag?(:linux) %}
        (rss || 0).should be > 1_000_000
      {% else %}
        (rss.nil? || rss > 0).should be_true
      {% end %}
    end

    it "counts uptime from the supplied start time" do
      provider_for(Azu::PerformanceMetrics.new, Time.utc - 90.seconds).uptime.total_seconds.should be_close(90.0, 1.0)
    end
  end

  describe "#routes" do
    it "hides the HEAD and OPTIONS routes Azu registers implicitly" do
      config = Azu::Configuration.new
      handler = Azu::Handler::RequestId.new
      config.router.get "/zeta", handler
      config.router.get "/alpha/:id", handler
      config.router.post "/alpha", handler

      Azu.with_config(config) do
        routes = provider_for(Azu::PerformanceMetrics.new).routes
        routes.map { |route| "#{route["method"]} #{route["path"]}" }.should eq(["POST /alpha", "GET /alpha/:id", "GET /zeta"])
      end
    end
  end
end

describe Azu::Components::Dashboard::Status do
  it "bands latency into good, warning and spike" do
    DashboardUI::Status.latency(299.9).should eq(DashboardUI::Status::Good)
    DashboardUI::Status.latency(300.0).should eq(DashboardUI::Status::Warn)
    DashboardUI::Status.latency(1000.0).should eq(DashboardUI::Status::Bad)
  end

  it "picks badge wording per level, treating neutral as good" do
    DashboardUI::Status::Bad.pick("Fast", "Slow", "Spike").should eq("Spike")
    DashboardUI::Status::Warn.pick("Fast", "Slow", "Spike").should eq("Slow")
    DashboardUI::Status::Good.pick("Fast", "Slow", "Spike").should eq("Fast")
    DashboardUI::Status::Idle.pick("Fast", "Slow", "Spike").should eq("Fast")
  end

  it "bands HTTP status codes" do
    DashboardUI::Status.http(204).should eq(DashboardUI::Status::Good)
    DashboardUI::Status.http(404).should eq(DashboardUI::Status::Warn)
    DashboardUI::Status.http(500).should eq(DashboardUI::Status::Bad)
  end
end

describe Azu::Components::Dashboard::Format do
  it "formats durations, sizes and counts for humans" do
    DashboardUI::Format.ms(0.456).should eq("0.46ms")
    DashboardUI::Format.ms(42.04).should eq("42.0ms")
    DashboardUI::Format.ms(2500.0).should eq("2.5s")
    DashboardUI::Format.megabytes(5 * 1024 * 1024).should eq("5.0 MB")
    DashboardUI::Format.number(1234567).should eq("1,234,567")
    DashboardUI::Format.uptime(3.days + 4.hours).should eq("3d 4h")
    DashboardUI::Format.uptime(75.seconds).should eq("1m 15s")
  end
end

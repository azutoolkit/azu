require "../../spec_helper"
require "../../../src/azu/dev/dev"

describe Azu::Dev::DashboardSnapshot do
  it "shares browser calculations and exports bounded, redacted data" do
    metrics = Azu::PerformanceMetrics.new
    [0.15, 2.0, 4.0, 16.7].each_with_index do |ms, i|
      metrics.record_request("Posts::Index", "GET", "/posts?password=secret-value", ms, 0_i64, 0_i64, i == 3 ? 422 : 200)
    end
    metrics.record_cache("private-cache-key", "get", "memory", 1.0, true, 17)
    config = Azu.current_config
    browser = Azu::Components::DashboardDataProvider.new(metrics, metrics.start_time, config.log)
    shared = Azu::Dev::DashboardSnapshot.new(metrics, metrics.start_time, config.log)
    data = JSON.parse(shared.telemetry(config).to_json)
    data["health"]["score"].as_i.should eq browser.health_score
    data["requests"]["p99_ms"].as_f.should eq browser.latency.not_nil!.p99
    data["requests"]["error_rate"].as_f.should eq browser.stats.error_rate
    data["series"]["traffic"].as_a.map(&.as_f).should eq browser.traffic_series
    data["cache"]["hit_rate"].as_f.should eq browser.cache_stats.hit_rate
    data["routes"]["total"].as_i.should eq browser.routes.size
    data.to_json.should_not contain "secret-value"
    data.to_json.should_not contain "private-cache-key"
    data["series"].as_h.each_value { |series| series.as_a.size.should be <= 120 }
  end

  it "does not turn missing cache reads or cookie sessions into zero" do
    config = Azu.current_config
    before = config.env
    config.env = Azu::Environment::Development
    Azu::Dev::IntegrationEvents.sessions("cookie", 42_i64)
    Azu::Dev::IntegrationEvents.session("sign-in", "accepted")
    Azu::Dev::IntegrationEvents.mailer("WelcomeMailer", "Static preview")
    Azu::Dev::IntegrationEvents.delivery("WelcomeMailer", "delivered")
    metrics = Azu::PerformanceMetrics.new
    data = JSON.parse(Azu::Dev::DashboardSnapshot.new(metrics, metrics.start_time, config.log).telemetry(config).to_json)
    data["cache"]["hit_rate"].raw.should be_nil
    data["sessions"]["active"].raw.should be_nil
    data["sessions"]["recent"][0]["outcome"].as_s.should eq "accepted"
    data["mailers"]["registered"][0]["preview"].as_s.should eq "Static preview"
  ensure
    config.env = before if config && before
    Azu::Dev::IntegrationEvents.reset
  end

  it "bounds optional event stores and rejects unknown outcomes" do
    config = Azu.current_config
    before = config.env
    config.env = Azu::Environment::Development
    150.times { Azu::Dev::IntegrationEvents.session("sign-in", "accepted") }
    Azu::Dev::IntegrationEvents.session("password", "secret")
    JSON.parse(Azu::Dev::IntegrationEvents.snapshot.to_json)["sessions"]["recent"].as_a.size.should eq 100
    config.env = Azu::Environment::Production
    Azu::Dev::IntegrationEvents.reset
    Azu::Dev::IntegrationEvents.delivery("WelcomeMailer", "delivered")
    JSON.parse(Azu::Dev::IntegrationEvents.snapshot.to_json)["mailers"]["recent"].as_a.should be_empty
  ensure
    config.env = before if config && before
    Azu::Dev::IntegrationEvents.reset
  end
end

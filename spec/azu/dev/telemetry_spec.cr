require "../../spec_helper"
require "../../../src/azu/dev/dev"

private def development_config : Azu::Configuration
  config = Azu::Configuration.new
  config.env = Azu::Environment::Development
  config
end

describe Azu::Dev::Telemetry do
  it "summarises requests, SQL and the heap in a versioned snapshot" do
    store = Azu::QueryStore.instance
    store.clear
    5.times { store.record_query("SELECT * FROM comments WHERE post_id = 1", [] of String, 0.5, 1_i64, nil, "index_page.cr:14", nil, "req-1", "Posts::IndexEndpoint", "GET", "/posts", 1_u64) }
    store.record_query("SELECT * FROM posts", [] of String, 120.0, 3_i64, nil, nil, nil, "req-1", "Posts::IndexEndpoint", "GET", "/posts", 1_u64)
    metrics = Azu::PerformanceMetrics.new
    metrics.record_request("Posts::IndexEndpoint", "GET", "/posts", 2.0, 0_i64, 0_i64, 200)
    metrics.record_request("Posts::CreateEndpoint", "POST", "/posts", 9.0, 0_i64, 0_i64, 422)

    json = JSON.parse(Azu::Dev::Telemetry.snapshot(development_config, metrics, store).to_json)

    json["v"].as_i.should eq 1
    json["requests"]["total"].as_i.should eq 2
    json["requests"]["errors_4xx"].as_i.should eq 1
    json["requests"]["recent"][0]["method"].as_s.should eq "POST"
    json["requests"]["recent"][0]["status"].as_i.should eq 422
    json["sql"]["total"].as_i.should eq 6
    json["sql"]["recent"].as_a.size.should eq 6
    json["sql"]["recent"][0]["ms"].as_f.should eq 120.0
    json["sql"]["histogram"].as_a.sum { |bucket| bucket["count"].as_i }.should eq 6
    json["sql"]["n_plus_one"][0]["count"].as_i.should eq 5
    json["sql"]["n_plus_one"][0]["caller"].as_s.should eq "index_page.cr:14"
    json["sql"]["slowest"][0]["ms"].as_f.should eq 120.0
    json["runtime"]["heap_bytes"].as_i64.should be > 0
  ensure
    Azu::QueryStore.instance.clear
  end

  it "redacts sensitive query parameters from request metrics before exporting them" do
    metrics = Azu::PerformanceMetrics.new
    metrics.record_request("CompatFailure", "GET", "/broken?password=do-not-export-this&name=Ada", 2.0, 0_i64, 0_i64, 500)
    json = JSON.parse(Azu::Dev::Telemetry.requests(metrics, Time.utc).to_json)
    json.to_json.should_not contain "do-not-export-this"
    json["recent"][0]["path"].as_s.should contain "name=Ada"
  end

  it "leaves requests out without a performance monitor" do
    json = JSON.parse(Azu::Dev::Telemetry.snapshot(development_config, nil).to_json)
    json["requests"].raw.should be_nil
  end

  it "writes snapshots to the socket azu dev listens on, in development only" do
    path = File.join(Dir.tempdir, "azu-telemetry-spec-#{Process.pid}.sock")
    File.delete?(path)
    server = UNIXServer.new(path)
    begin
      production = Azu::Configuration.new
      production.env = Azu::Environment::Production
      Azu::Dev::Telemetry.start(production, path)
      Azu::Dev::Telemetry.start(development_config, nil)

      Azu::Dev::Telemetry.start(development_config, path)
      client = server.accept
      line = client.gets || fail "no snapshot arrived"
      JSON.parse(line)["v"].as_i.should eq 1
      client.close
    ensure
      server.close
      File.delete?(path)
      Azu::Dev::Telemetry.reset
    end
  end
end

describe "terminal diagnostics telemetry" do
  it "buckets latency without counting invalid timings" do
    buckets = Azu::Dev::Telemetry.histogram([0.5, 1.0, 5.0, 10.0, 50.0, 100.0, Float64::NAN, -1.0])
    buckets.map(&.[:count]).should eq [1, 1, 1, 1, 1, 1]
    buckets.map(&.[:bar]).should eq [12, 12, 12, 12, 12, 12]
  end

  it "receives rescuer reports with request secrets filtered" do
    store = Azu::ErrorStore.instance
    store.clear
    config = development_config
    context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/broken?password=do-not-export&name=Ada"), HTTP::Server::Response.new(IO::Memory.new))
    rescuer = Azu::Handler::Rescuer.new
    rescuer.next = ->(_context : HTTP::Server::Context) { raise "terminal report integration" }
    Azu.with_config(config) { rescuer.call(context) }
    json = Azu::Dev::Telemetry.errors(store).to_json
    json.should contain "terminal report integration"
    json.should_not contain "do-not-export"
    JSON.parse(json).as_a.first["problem"]["status"].as_i.should eq 500
  ensure
    store.try(&.clear)
  end

  it "exports bounded recent reports with problem details and redacted parameters" do
    store = Azu::ErrorStore.new
    none = [] of {String, String}
    request = Azu::ExceptionPage::RequestInfo.new("request-1", "POST", "/login", "/login", nil, nil, nil, nil,
      [{"password", "[FILTERED]"}], none, none, none, none)
    12.times do
      report = Azu::ExceptionPage::Report.new(500, "RuntimeError", "failure", [] of Azu::ExceptionPage::Frame,
        [] of Azu::ExceptionPage::Cause, request)
      store.record(report)
    end
    rows = JSON.parse(Azu::Dev::Telemetry.errors(store).to_json).as_a
    rows.size.should eq 10
    rows.first["problem"]["status"].as_i.should eq 500
    rows.first["params"].to_json.should contain "[FILTERED]"
    store.recent(0).should be_empty
  end
end

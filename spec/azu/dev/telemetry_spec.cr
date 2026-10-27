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
    json["sql"]["n_plus_one"][0]["count"].as_i.should eq 5
    json["sql"]["n_plus_one"][0]["caller"].as_s.should eq "index_page.cr:14"
    json["sql"]["slowest"][0]["ms"].as_f.should eq 120.0
    json["runtime"]["heap_bytes"].as_i64.should be > 0
  ensure
    Azu::QueryStore.instance.clear
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

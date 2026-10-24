require "../../spec_helper"
require "compress/gzip"

private def serve_client_asset(headers = HTTP::Headers.new, query = "", method = "GET")
  io = IO::Memory.new
  request = HTTP::Request.new(method, "/_spark/azu_spark.js#{query}", headers)
  context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
  Azu::Spark::Client::Asset.new.call(context)
  context.response.close
  io.rewind
  HTTP::Client::Response.from_io(io)
end

# The readable source of the client; the embedded script is built from it (js/build.mjs).
private CLIENT_JS = File.read(File.join(__DIR__, "../../../js/azu-spark.js"))
private REBUILD   = "run `npm install && npm run build` in js/ and commit src/azu/spark/client/azu_spark.js"

describe Azu::Spark::Client do
  it "ships the script built from js/azu-spark.js (recorded source hash matches)" do
    recorded = Azu::Spark::Client::SOURCE[/\A\/\*! azu-spark src-sha256:([0-9a-f]{64})/, 1]?
    recorded.should_not be_nil, "azu_spark.js has no source hash header: #{REBUILD}"
    recorded.should eq(Digest::SHA256.hexdigest(CLIENT_JS)), "js/azu-spark.js changed without rebuilding the script: #{REBUILD}"
  end

  # 8 KB held until the delivery layer (numbered events, an unacknowledged-event queue, coalescing,
  # IME and debounce handling) was added; 10 KB held for the whole client with it. Observability, the
  # live region and the idle close (slice 5) raised the budget to 10.5 KB (10_752). Optional gzip
  # frames (slice 6: announcing them, the ordered inflate line, the streaming size limit and the
  # recovery from an unreadable frame, about 350 bytes) raised it to 11 KB (11_264).
  it "stays within the 11 KB gzip budget" do
    io = IO::Memory.new
    Compress::Gzip::Writer.open(io, Compress::Deflate::BEST_COMPRESSION, &.print(Azu::Spark::Client::SOURCE))
    io.size.should be <= 11_264, "the client grew to #{io.size} bytes gzipped (budget 11264)"
  end

  it "announces gzip only where DecompressionStream exists, and inflates with a size limit" do
    source = Azu::Spark::Client::SOURCE
    source.should contain("DecompressionStream")
    source.should contain(%("gzip"))
    source.should contain(Azu::Spark::Protocol::MAX_INFLATED.to_s)
    CLIENT_JS.should contain(%(typeof DecompressionStream === "function"))
    CLIENT_JS.should contain(%(binaryType = "arraybuffer"))
  end

  it "ships the script inside the shard, with no CDN or library dependency" do
    Azu::Spark::Client::SOURCE.should contain("WebSocket")
    Azu::Spark::Client::SOURCE.should_not contain("unpkg")
    Azu::Spark::Client::SOURCE.should_not contain("jquery")
    Azu::Spark::Client::SOURCE.should_not match(/https?:\/\/(?!\*)/)
  end

  it "parses patches through the named Trusted Types policy and never assigns innerHTML" do
    Azu::Spark::Client::SOURCE.should contain(%("azu-spark"))
    Azu::Spark::Client::SOURCE.should contain("createHTML")
    Azu::Spark::Client::SOURCE.should_not contain("createScript")
    Azu::Spark::Client::SOURCE.should_not contain("innerHTML")
    Azu::Spark::Client::SOURCE.should_not contain("eval(")
    CLIENT_JS.should contain("createPolicy(\"azu-spark\"")
  end

  it "implements reconnect with exponential backoff, heartbeat and rehydration" do
    source = CLIENT_JS
    source.should contain("Math.pow(2, attempt)")
    source.should contain(%("heartbeat"))
    source.should contain("snapshots.get(id)")
  end

  it "drives the connection with an explicit state machine" do
    source = CLIENT_JS
    source.should contain("export var TRANSITIONS")
    source.should contain("export function next(")
    source.should contain("performance.now()")
  end

  it "queues events while offline and reacts to the browser's offline and visibility events" do
    source = CLIENT_JS
    source.should contain("queueMax")
    source.should contain(%("offline"))
    source.should contain("visibilitychange")
    source.should contain(%("invalid_snapshot"))
  end

  it "numbers events, keeps them until acknowledged and resends them after a reconnect" do
    source = CLIENT_JS
    source.should contain("eid")
    source.should contain(%("event_dropped"))
    source.should contain(%("stale_event"))
    source.should contain("at-most-once")
    source.should contain("isComposing")
  end

  it "versions the asset path by content hash" do
    Azu::Spark.asset_path.should eq "/_spark/azu_spark.js?v=#{Azu::Spark::Client::VERSION}"
  end

  it "builds a pinned script tag" do
    tag = Azu::Spark.script_tag
    tag.should contain("/_spark/azu_spark.js?v=#{Azu::Spark::Client::VERSION}")
    tag.should contain("defer")
    tag.should_not contain("http")
  end

  describe Azu::Spark::Client::Asset do
    it "serves the script as immutable when the version matches" do
      response = serve_client_asset(query: "?v=#{Azu::Spark::Client::VERSION}")
      response.status_code.should eq 200
      response.content_type.should eq "application/javascript"
      response.headers["Cache-Control"].should contain("immutable")
      response.body.should eq Azu::Spark::Client::SOURCE
    end

    it "only answers GET and HEAD, and understands lists and weak forms of If-None-Match" do
      response = serve_client_asset(method: "POST")
      response.status_code.should eq 405
      response.headers["Allow"].should eq "GET, HEAD"
      tag = %("#{Azu::Spark::Client::VERSION}")
      serve_client_asset(HTTP::Headers{"If-None-Match" => %("other", W/#{tag})}).status_code.should eq 304
      serve_client_asset(HTTP::Headers{"If-None-Match" => %("other")}).status_code.should eq 200
    end

    it "makes browsers revalidate without a version and answers conditional requests" do
      serve_client_asset.headers["Cache-Control"].should eq "no-cache"
      headers = HTTP::Headers{"If-None-Match" => %("#{Azu::Spark::Client::VERSION}")}
      response = serve_client_asset(headers)
      response.status_code.should eq 304
      response.body.should be_empty
    end
  end

  it "registers the script route together with the socket" do
    router = Azu::Router.new
    Azu::Spark.install(router)
    router.route_info.map { |r| r["path"] }.should contain(Azu::Spark.config.assets_path)
  end
end

require "../../spec_helper"

private def serve_client_asset(headers = HTTP::Headers.new, query = "", method = "GET")
  io = IO::Memory.new
  request = HTTP::Request.new(method, "/_spark/azu_spark.js#{query}", headers)
  context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
  Azu::Spark::Client::Asset.new.call(context)
  context.response.close
  io.rewind
  HTTP::Client::Response.from_io(io)
end

describe Azu::Spark::Client do
  it "ships the script inside the shard, with no CDN or library dependency" do
    Azu::Spark::Client::SOURCE.should contain("WebSocket")
    Azu::Spark::Client::SOURCE.should_not contain("unpkg")
    Azu::Spark::Client::SOURCE.should_not contain("jquery")
    Azu::Spark::Client::SOURCE.should_not match(/https?:\/\/(?!\*)/)
  end

  it "implements reconnect with exponential backoff, heartbeat and rehydration" do
    source = Azu::Spark::Client::SOURCE
    source.should contain("Math.pow(2, attempt)")
    source.should contain(%("heartbeat"))
    source.should contain("snapshots.get(id)")
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

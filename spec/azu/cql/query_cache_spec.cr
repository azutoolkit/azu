require "../../spec_helper"
require "http/client"
require "sqlite3"
require "../../../src/azu/cql"

# A real Azu::App behind Azu::CQL::Middleware(query_cache: true), against SQLite, so a change on either side of the
# bridge (azu's middleware, CQL's request cache API) breaks here.
module QueryCacheSpec
  DB_FILE = File.tempname("azu_cql_query_cache", ".db")

  def self.build_schema : CQL::Schema
    File.delete?(DB_FILE)
    schema = Azu::CQL.schema(:query_cache, "sqlite3://#{DB_FILE}?busy_timeout=5000", lazy: false) do
      table :notes do
        primary :id, Int64
        column :title, String
      end
    end
    schema.build
    schema
  end

  SCHEMA = build_schema

  struct NoParams
    include Azu::Request

    def initialize
    end
  end

  struct StatsResponse
    include Azu::Response

    def initialize(@stats : Azu::CQL::RequestCacheStats?, @cql_request_id : String, @tracking : Bool)
    end

    def render : String
      stats = @stats
      {
        request_id:     stats.try(&.request_id),
        queries:        stats.try(&.queries),
        repeated:       stats.try(&.repeated),
        cql_request_id: @cql_request_id,
        tracking:       @tracking,
      }.to_json
    end
  end

  # The same SELECT three times and another one once.
  struct Repeat
    include Azu::Endpoint(NoParams, StatsResponse)

    get "/notes/repeat"

    def call : StatsResponse
      3.times do
        SCHEMA.query.from(:notes).select(:title).all(String)
        sleep 2.milliseconds # concurrent requests interleave here
      end
      SCHEMA.query.from(:notes).select(:id).all(Int64)
      StatsResponse.new(Azu::CQL.request_cache_stats, CQL::Cache::RequestQueryCacheHelper.stats["request_id"].to_s, CQL::Cache::RequestQueryCacheHelper.enabled?)
    end
  end

  struct Boom
    include Azu::Endpoint(NoParams, StatsResponse)

    get "/notes/boom"

    def call : StatsResponse
      SCHEMA.query.from(:notes).select(:title).all(String)
      raise "boom"
    end
  end

  def self.serve(query_cache : Bool = true, &)
    app = Azu::App.new
    app.routes do
      endpoint Repeat
      endpoint Boom
    end
    handlers = [Azu::Handler::RequestId.new, Azu::Handler::Rescuer.new, Azu::CQL::Middleware.new(SCHEMA, query_cache: query_cache)] of HTTP::Handler
    server = app.server(handlers)
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield
    begin
      yield "http://#{address.address}:#{address.port}"
    ensure
      server.close
    end
  end

  # CQL's request cache records nothing unless the cache and its request cache are switched on.
  def self.with_cql_cache(&)
    cache = ::CQL.config.cache
    on, request_cache = cache.on?, cache.request_cache?
    cache.on = true
    cache.request_cache = true
    begin
      yield
    ensure
      cache.on = on
      cache.request_cache = request_cache
    end
  end

  def self.get(base : String, path : String, request_id : String) : HTTP::Client::Response
    HTTP::Client.get("#{base}#{path}", HTTP::Headers{"Accept" => "application/json", "X-Request-ID" => request_id})
  end
end

describe "Azu::CQL::Middleware query_cache" do
  it "opens CQL's request cache for the request, under the X-Request-ID the client sent" do
    QueryCacheSpec.with_cql_cache do
      QueryCacheSpec.serve do |base|
        body = JSON.parse(QueryCacheSpec.get(base, "/notes/repeat", "req-repeat").body)
        body["cql_request_id"].should eq "req-repeat"
        body["tracking"].should be_true
      end
    end
  end

  it "counts the statements the request repeated, from zero for each request" do
    QueryCacheSpec.with_cql_cache do
      QueryCacheSpec.serve do |base|
        2.times do |attempt|
          body = JSON.parse(QueryCacheSpec.get(base, "/notes/repeat", "req-count-#{attempt}").body)
          body["request_id"].should eq "req-count-#{attempt}"
          body["queries"].should eq 4
          body["repeated"].should eq 2
        end
      end
    end
  end

  it "has no stats while CQL's cache is off" do
    QueryCacheSpec.serve do |base|
      body = JSON.parse(QueryCacheSpec.get(base, "/notes/repeat", "req-off").body)
      body["queries"].raw.should be_nil
      body["tracking"].should be_false
    end
  end

  it "leaves CQL's request cache alone by default" do
    QueryCacheSpec.with_cql_cache do
      QueryCacheSpec.serve(query_cache: false) do |base|
        before = CQL::Cache::RequestQueryCacheHelper.stats
        body = JSON.parse(QueryCacheSpec.get(base, "/notes/repeat", "req-default").body)
        body["tracking"].should be_false
        body["queries"].raw.should be_nil
        CQL::Cache::RequestQueryCacheHelper.stats.should eq before
      end
    end
  end

  it "ends the request's cache scope when the endpoint raises" do
    QueryCacheSpec.with_cql_cache do
      QueryCacheSpec.serve do |base|
        QueryCacheSpec.get(base, "/notes/boom", "req-boom").status_code.should eq 500
        CQL::Cache::RequestQueryCacheHelper.enabled?.should be_false
        CQL::Cache::RequestQueryCacheHelper.stats["request_id"].should eq "none"
      end
    end
  end

  it "ends the scope and forgets the request's stats when the block raises" do
    QueryCacheSpec.with_cql_cache do
      expect_raises(Exception, "boom") do
        Azu::CQL::RequestCache.scope("req-raise") do
          Azu::CQL.request_cache_stats.try(&.request_id).should eq "req-raise"
          raise "boom"
        end
      end
      Azu::CQL.request_cache_stats.should be_nil
      CQL::Cache::RequestQueryCacheHelper.enabled?.should be_false
    end
  end

  # CQL's request cache is one process-wide tracker (cql 0.0.921): overlapping requests share its counters, so each
  # request's counts include the others'. Enable this once cql keeps request state per fiber (the follow-up planned
  # in azutoolkit/cql#63); Azu's side, the request id and the per-fiber baseline, is already per request.
  pending "keeps the stats of concurrent requests apart (needs per-request state in cql, azutoolkit/cql#63)" do
    QueryCacheSpec.with_cql_cache do
      QueryCacheSpec.serve do |base|
        done = Channel(JSON::Any).new
        ids = (1..4).map { |index| "req-parallel-#{index}" }
        ids.each { |id| spawn { done.send(JSON.parse(QueryCacheSpec.get(base, "/notes/repeat", id).body)) } }
        bodies = ids.map { done.receive }
        bodies.map(&.["request_id"].as_s).sort!.should eq ids
        bodies.each do |body|
          body["queries"].should eq 4
          body["repeated"].should eq 2
        end
      end
    end
  end
end

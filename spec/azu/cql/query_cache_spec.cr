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

    def initialize(@cql_request_id : String, @tracking : Bool)
    end

    def render : String
      {cql_request_id: @cql_request_id, tracking: @tracking}.to_json
    end
  end

  struct Repeat
    include Azu::Endpoint(NoParams, StatsResponse)

    get "/notes/repeat"

    def call : StatsResponse
      SCHEMA.query.from(:notes).select(:title).all(String)
      StatsResponse.new(CQL::Cache::RequestQueryCacheHelper.stats["request_id"].to_s, CQL::Cache::RequestQueryCacheHelper.enabled?)
    end
  end

  def self.serve(query_cache : Bool = true, &)
    app = Azu::App.new
    app.routes do
      endpoint Repeat
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
end

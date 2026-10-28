require "../../spec_helper"
require "http/client"
require "sqlite3"
require "../../../src/azu/cql"

# `Azu::CQL::Middleware.new(query_cache: true)` against a real `Azu::App` served over a socket, with CQL's
# request query cache on: the repeated SELECTs of a request are counted for that request.
module QueryCacheSpec
  class_property slow_started : Channel(Nil)?
  class_property resume_slow : Channel(Nil)?

  DB_FILE = File.tempname("azu_cql_query_cache", ".db")

  def self.build_schema : CQL::Schema
    File.delete?(DB_FILE)
    schema = Azu::CQL.schema(:query_cache, "sqlite3://#{DB_FILE}?busy_timeout=5000", lazy: false) do
      table :items do
        primary :id, Int64
        column :name, String
      end
    end
    schema.build
    schema.exec("INSERT INTO items (id, name) VALUES (1, 'one'), (2, 'two')")
    schema
  end

  SCHEMA = build_schema

  def self.name_of(id : Int64) : Array(String)
    SCHEMA.query.from(:items).select(:name).where(id: id).all(String)
  end

  struct Json
    include Azu::Response

    def initialize(@body : String)
    end

    def render
      @body
    end
  end

  def self.stats_json : String
    stats = Azu::CQL.request_cache_stats
    tracker = ::CQL::Cache::RequestQueryCacheHelper.stats
    {
      stats:   stats.try { |found| {request_id: found.request_id, queries: found.queries, repeated: found.repeated, distinct: found.distinct} },
      tracker: {enabled: ::CQL::Cache::RequestQueryCacheHelper.enabled?, request_id: tracker["request_id"]},
    }.to_json
  end

  # The same SELECT three times, and one other.
  struct Repeat
    include Azu::Endpoint(Azu::Request, Json)

    get "/repeat"

    def call : Json
      3.times { QueryCacheSpec.name_of(1) }
      QueryCacheSpec.name_of(2)
      content_type "application/json"
      Json.new(QueryCacheSpec.stats_json)
    end
  end

  struct Failing
    include Azu::Endpoint(Azu::Request, Json)

    get "/failing"

    def call : Json
      2.times { QueryCacheSpec.name_of(1) }
      raise "boom"
    end
  end

  # A slow request with a repeated SELECT, and a quick one that starts and finishes while the slow one waits.
  struct Slow
    include Azu::Endpoint(Azu::Request, Json)

    get "/slow"

    def call : Json
      QueryCacheSpec.name_of(1)
      QueryCacheSpec.slow_started.try(&.send(nil))
      QueryCacheSpec.resume_slow.try(&.receive)
      2.times { QueryCacheSpec.name_of(1) }
      content_type "application/json"
      Json.new(QueryCacheSpec.stats_json)
    end
  end

  struct Quick
    include Azu::Endpoint(Azu::Request, Json)

    get "/quick"

    def call : Json
      2.times { QueryCacheSpec.name_of(2) }
      content_type "application/json"
      Json.new(QueryCacheSpec.stats_json)
    end
  end

  def self.serve(query_cache : Bool = true, transaction : Bool = false, &)
    app = Azu::App.new
    app.routes do
      endpoint Repeat
      endpoint Failing
      endpoint Slow
      endpoint Quick
    end
    handlers = [Azu::Handler::RequestId.new, Azu::Handler::Rescuer.new, Azu::CQL::Middleware.new(SCHEMA, transaction: transaction, query_cache: query_cache)] of HTTP::Handler
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

  def self.get(base : String, path : String, request_id : String) : JSON::Any
    response = HTTP::Client.get("#{base}#{path}", HTTP::Headers{"X-Request-ID" => request_id, "Accept" => "application/json"})
    response.status_code.should eq 200
    JSON.parse(response.body)
  end

  # Runs the block with CQL's request query cache on (or off), whatever the environment's default is.
  def self.with_cql_cache(on : Bool = true, &)
    cache = ::CQL.config.cache
    was_on, was_request = cache.on?, cache.request_cache?
    cache.on = on
    cache.request_cache = on
    begin
      yield
    ensure
      cache.on = was_on
      cache.request_cache = was_request
    end
  end

  def self.counters : {Int64, Int64}
    stats = ::CQL::Cache::RequestQueryCacheHelper.stats
    {stats["hits"]?.as?(Int64) || 0_i64, stats["misses"]?.as?(Int64) || 0_i64}
  end
end

describe "Azu::CQL::Middleware query_cache:" do
  it "counts the repeated queries of a request under the X-Request-ID the client sent" do
    QueryCacheSpec.with_cql_cache do
      QueryCacheSpec.serve do |base|
        body = QueryCacheSpec.get(base, "/repeat", "req-repeat-1")
        body["stats"]["request_id"].should eq "req-repeat-1"
        body["stats"]["queries"].should eq 4
        body["stats"]["repeated"].should eq 2
        body["stats"]["distinct"].should eq 2
        body["tracker"]["request_id"].should eq "req-repeat-1"
        body["tracker"]["enabled"].should be_true

        again = QueryCacheSpec.get(base, "/repeat", "req-repeat-2") # counts start over for each request
        again["stats"].should eq JSON.parse({request_id: "req-repeat-2", queries: 4, repeated: 2, distinct: 2}.to_json)
      end
      ::CQL::Cache::RequestQueryCacheHelper.enabled?.should be_false
      Azu::CQL.request_cache_stats.should be_nil
    end
  end

  it "leaves CQL's tracker untouched by default" do
    Azu::CQL::Middleware.new(QueryCacheSpec::SCHEMA).query_cache?.should be_false
    QueryCacheSpec.with_cql_cache do
      before = QueryCacheSpec.counters
      QueryCacheSpec.serve(query_cache: false) do |base|
        body = QueryCacheSpec.get(base, "/repeat", "req-off")
        body["stats"].raw.should be_nil
        body["tracker"]["enabled"].should be_false
      end
      QueryCacheSpec.counters.should eq before
    end
  end

  it "reports nothing when CQL's request cache is off" do
    QueryCacheSpec.with_cql_cache(on: false) do
      QueryCacheSpec.serve do |base|
        body = QueryCacheSpec.get(base, "/repeat", "req-cql-off")
        body["stats"].raw.should be_nil
        body["tracker"]["enabled"].should be_false
      end
    end
  end

  it "ends the tracker when the endpoint raises" do
    QueryCacheSpec.with_cql_cache do
      QueryCacheSpec.serve do |base|
        response = HTTP::Client.get("#{base}/failing", HTTP::Headers{"X-Request-ID" => "req-failing"})
        response.status_code.should eq 500
        ::CQL::Cache::RequestQueryCacheHelper.enabled?.should be_false

        QueryCacheSpec.get(base, "/repeat", "req-after")["stats"]["repeated"].should eq 2
      end
    end
  end

  it "counts inside a request transaction and ends the tracker when it rolls back" do
    QueryCacheSpec.with_cql_cache do
      QueryCacheSpec.serve(transaction: true) do |base|
        QueryCacheSpec.get(base, "/repeat", "req-tx")["stats"]["repeated"].should eq 2
        HTTP::Client.get("#{base}/failing").status_code.should eq 500
        ::CQL::Cache::RequestQueryCacheHelper.enabled?.should be_false
      end
    end
  end

  it "keeps the counts of concurrent requests apart" do
    QueryCacheSpec.with_cql_cache do
      QueryCacheSpec.serve do |base|
        started = Channel(Nil).new(1)
        resume = Channel(Nil).new(1)
        QueryCacheSpec.slow_started = started
        QueryCacheSpec.resume_slow = resume
        slow = Channel(JSON::Any).new(1)
        spawn { slow.send QueryCacheSpec.get(base, "/slow", "req-slow") }
        select
        when started.receive
        when timeout(5.seconds)
          fail "slow request did not reach its first query"
        end
        quick = QueryCacheSpec.get(base, "/quick", "req-quick")
        quick["stats"]["request_id"].should eq "req-quick"
        quick["stats"]["queries"].should eq 2
        quick["stats"]["repeated"].should eq 1

        resume.send(nil)
        slow_stats = select
        when response = slow.receive
          response["stats"]
        when timeout(5.seconds)
          fail "slow request did not finish"
        end
        slow_stats["request_id"].should eq "req-slow"
        slow_stats["queries"].should eq 3
        slow_stats["repeated"].should eq 2
      ensure
        resume.try(&.close)
        QueryCacheSpec.slow_started = nil
        QueryCacheSpec.resume_slow = nil
      end
    end
  end
end

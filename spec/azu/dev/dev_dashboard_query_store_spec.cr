require "cql"
require "../../spec_helper"
require "../../../src/azu/dev/dev"
require "../../support/integration_helpers"

include IntegrationHelpers

# Database tab fed by `Azu::QueryStore` (what `azu/cql` records) instead of CQL's monitor.
private class StubAdapter < Azu::DatabaseAdapter
  getter executed = [] of String

  def read_only(sql : String, limit : Int32) : {Array(String), Array(Array(String?))}
    @executed << sql
    {["one"], [["1"] of String?, [nil] of String?]}
  end

  def pool : Azu::PoolSnapshot?
    Azu::PoolSnapshot.new(open: 3, idle: 1, in_flight: 0, max: 10)
  end

  def dialect : String
    "sqlite"
  end

  def adapter_name : String?
    "TestDB"
  end

  def connection_source : String?
    "spec pool"
  end
end

private class EmptyPoolAdapter < StubAdapter
  def pool : Azu::PoolSnapshot?
    Azu::PoolSnapshot.new(open: 0, idle: 0, in_flight: 0, max: 5)
  end
end

private def dashboard_page : String
  Azu::Components::DevDashboardComponent.new(Azu::PerformanceMetrics.new).render
end

private def post_sql(handler, body : String, remote = "127.0.0.1", headers = HTTP::Headers{"X-Requested-With" => "azu-dashboard"})
  context, io = create_context_with_remote_addr("POST", "/dev-dashboard/sql", remote, headers)
  context.request.body = IO::Memory.new(body)
  handler.call(context)
  {context, get_response_body(context, io)}
end

private def add_query(store : Azu::QueryStore, sql : String, ms = 1.0, request = "req-1", tx : Int64? = nil, error : String? = nil)
  store.record_query(sql, [] of String, ms, 1_i64, error, "src/app.cr:10", tx, request, "UsersEndpoint", "GET", "/users", 1_u64)
end

describe "Dev dashboard Database tab backed by the query store" do
  store = Azu::QueryStore.instance

  before_each do
    store.clear
    store.enabled = false
    store.adapter = nil
    # cql is a development dependency and the whole suite compiles it in, so the tab would
    # otherwise read CQL's global monitor, which is on by default. Start from one that is off.
    CQL::Performance.monitor = CQL::Performance::Monitor.new(CQL::Performance::Config.new { |config| config.monitoring.enabled = false })
  end

  after_all do
    store.clear
    store.enabled = false
    store.adapter = nil
    CQL::Performance.monitor = CQL::Performance::Monitor.new
  end

  it "keeps the n/a state until an ORM integration records queries" do
    dashboard_page.should contain("CQL performance monitoring is not active")
  end

  it "shows recorded queries with their request, call site and timing badge" do
    store.enabled = true
    add_query(store, "SELECT * FROM users WHERE id = 1", ms: 2.0)
    add_query(store, "SELECT pg_sleep(1)", ms: 120.0)
    add_query(store, "INSERT INTO nope", ms: 1.0, error: "relation does not exist")

    html = dashboard_page
    html.should_not contain("CQL performance monitoring is not active")
    html.should contain("Recent queries")
    html.should contain("SELECT * FROM users WHERE id = 1")
    html.should contain("GET /users")
    html.should contain("UsersEndpoint")
    html.should contain("src/app.cr:10")
    html.should contain("relation does not exist")
    html.should contain("Slow queries")
    html.should contain("SELECT pg_sleep(1)")
  end

  it "reports a repeated query shape within one request as an N+1 with a preload hint" do
    store.enabled = true
    4.times { |i| add_query(store, "SELECT * FROM posts WHERE posts.user_id = #{i}") }

    html = dashboard_page
    html.should contain("N+1 analysis")
    html.should contain("4x SELECT * FROM posts WHERE posts.user_id = ?")
    html.should contain("UsersEndpoint at src/app.cr:10")
    html.should contain("preload(:posts)")
  end

  it "lists transactions and pool usage" do
    store.enabled = true
    store.adapter = StubAdapter.new
    store.record_transaction_begin(5_i64, false, "req-1", "UsersEndpoint")
    add_query(store, "UPDATE users SET name = 'x'", tx: 5_i64)
    store.record_transaction_end(5_i64, false, 4.2)

    html = dashboard_page
    html.should contain("#5")
    html.should contain("rolled back")
    html.should contain("Connection pool")
    html.should contain("role='meter'")
  end

  describe "CQL telemetry details" do
    it "shows the connection wait, the tag, shown values and the error text of a statement" do
      store.enabled = true
      store.record_query("SELECT * FROM users WHERE id = ?", ["7"], 80.0, nil, nil, "src/app.cr:10", nil, "req-1", "UsersEndpoint", "GET", "/users", 1_u64,
        pool_wait_ms: 42.0, context: "job:nightly")
      store.record_query("SELECT 1", ["?"], 1.0, nil, "no such table: x", nil, nil, "req-1", "UsersEndpoint", "GET", "/users", 1_u64)

      html = dashboard_page
      html.scan("waited 42.0ms for a connection").size.should eq 2 # recent queries and slow queries
      html.should contain("params: 7")
      html.should contain("tag: job:nightly")
      html.should contain("1 failed")
      html.should contain("GET /users at src/app.cr:10") # the slow query's request and call site
      html.should_not contain("params: ?")
    end

    it "labels nested transactions and shows why a transaction rolled back" do
      store.enabled = true
      store.record_transaction_begin(1_i64, false, "req-1", "UsersEndpoint")
      store.record_transaction_begin(2_i64, true, "req-1", "UsersEndpoint")
      store.record_transaction_end(2_i64, false, 1.0)
      store.record_transaction_end(1_i64, false, 3.0, "deadlock detected")

      html = dashboard_page
      html.should contain("#2 (nested)")
      html.should contain("deadlock detected")
    end

    it "describes the pool: database, connection source, pool waits and the unopened pool" do
      store.enabled = true
      store.adapter = StubAdapter.new
      store.record_query("SELECT 1", ["?"], 60.0, nil, nil, nil, nil, "req-1", "E", "GET", "/", 1_u64, pool_wait_ms: 30.0)

      html = dashboard_page
      html.should contain("Pool waits")
      html.should contain("1 statements, longest 30.0ms")
      html.should contain("Database")
      html.should contain("TestDB")
      html.should contain("spec pool")

      store.clear
      store.adapter = EmptyPoolAdapter.new
      dashboard_page.should contain("No connection is open yet")
    end

    it "lowers the health score for failed statements" do
      Azu::Components::Dashboard::DatabaseData::DatabaseStats.new(true, 10_i64, 2, 5.0, 1.0, 9.0, 0, 0, 0, 0, 0, errors: 5).health.should eq 90
    end
  end

  describe "serving app configuration" do
    # The dashboard answers for the app serving the request: its environment, playground switch and thresholds, not the
    # global configuration's.
    it "offers the playground and applies the app's thresholds although the global configuration is production" do
      development = Azu::Configuration.new
      development.env = Azu::Environment::Development
      development.database.n_plus_one_threshold = 10
      store.enabled = true
      store.adapter = StubAdapter.new
      4.times { |i| add_query(store, "SELECT * FROM posts WHERE posts.user_id = #{i}") }

      with_azu_env(Azu::Environment::Production) do
        Azu.with_config(development) do
          html = dashboard_page
          html.should contain("id='azd-sql'")
          html.should_not contain("4x SELECT * FROM posts") # 4 repeats stay under the app's threshold of 10
        end
        Azu.with_config(Azu::Configuration.new) { dashboard_page.should contain("4x SELECT * FROM posts") } # the default threshold is 3
      end
    end

    it "hides the playground when the app switched it off, whatever the global configuration says" do
      quiet = Azu::Configuration.new
      quiet.env = Azu::Environment::Development
      quiet.database.playground = false
      store.enabled = true
      store.adapter = StubAdapter.new

      with_azu_env(Azu::Environment::Development) do
        Azu.with_config(quiet) { dashboard_page.should_not contain("id='azd-sql'") }
      end
    end
  end

  describe "SQL playground" do
    handler = Azu::Handler::DevDashboard.new
    around_each { |example| with_azu_env(Azu::Environment::Development) { example.run } }

    it "is offered only in development with a database attached" do
      store.enabled = true
      with_azu_env(Azu::Environment::Development) { dashboard_page.should_not contain("id='azd-sql'") }
      store.adapter = StubAdapter.new
      with_azu_env(Azu::Environment::Development) { dashboard_page.should contain("id='azd-sql'") }
      with_azu_env(Azu::Environment::Production) { dashboard_page.should_not contain("id='azd-sql'") }
    end

    it "runs read-only statements and wraps explain" do
      adapter = StubAdapter.new
      store.adapter = adapter
      with_azu_env(Azu::Environment::Development) do
        context, body = post_sql(handler, %({"sql":"SELECT 1","mode":"run"}))
        context.response.status_code.should eq 200
        result = JSON.parse(body)
        result["columns"].as_a.map(&.as_s).should eq ["one"]
        result["rows"].as_a.size.should eq 2

        post_sql(handler, %({"sql":"SELECT 1","mode":"explain"}))
        adapter.executed.should eq ["SELECT 1", "EXPLAIN QUERY PLAN SELECT 1"]
      end
    end

    it "refuses writes, remote clients, missing headers, cross-origin posts and other environments" do
      adapter = StubAdapter.new
      store.adapter = adapter

      with_azu_env(Azu::Environment::Development) do
        post_sql(handler, %({"sql":"DELETE FROM users","mode":"run"}))[0].response.status_code.should eq 400
        post_sql(handler, %({"sql":"INSERT INTO t VALUES (1)","mode":"explain"}))[0].response.status_code.should eq 400
        post_sql(handler, %({"sql":"SELECT 1","mode":"run"}), remote: "10.0.0.5")[0].response.status_code.should eq 404
        post_sql(handler, %({"sql":"SELECT 1","mode":"run"}), headers: HTTP::Headers.new)[0].response.status_code.should eq 403
        cross = HTTP::Headers{"X-Requested-With" => "azu-dashboard", "Origin" => "http://evil.test", "Host" => "localhost:4000"}
        post_sql(handler, %({"sql":"SELECT 1"}), headers: cross)[0].response.status_code.should eq 403
        post_sql(handler, "not json")[0].response.status_code.should eq 400
      end

      with_azu_env(Azu::Environment::Production) do
        post_sql(handler, %({"sql":"SELECT 1","mode":"run"}))[0].response.status_code.should eq 404
      end
      adapter.executed.should be_empty
    end
  end

  it "clears recorded queries with ?clear=true" do
    store.enabled = true
    add_query(store, "SELECT 1")
    context, _io = create_context("GET", "/dev-dashboard?clear=true")
    with_azu_env(Azu::Environment::Development) { Azu::Handler::DevDashboard.new.call(context) }
    store.queries.should be_empty
  end
end

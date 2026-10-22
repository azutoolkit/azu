require "../../spec_helper"
require "../../support/integration_helpers"
require "sqlite3"
require "pg"
require "../../../src/azu/cql"

include IntegrationHelpers

private DB_FILE     = File.join(Dir.tempdir, "azu_cql_config_spec.db")
private UNREACHABLE = "postgres://postgres:secret@127.0.0.1:1/azu_unreachable"

# CQL.config is a process-wide singleton: put it back the way the other specs expect.
private def with_cql_config(&)
  yield
ensure
  ::CQL.reset_config!
end

private def dashboard : String
  context, io = create_context("GET", "/dev-dashboard")
  Azu::Handler::DevDashboard.new.call(context)
  context.response.close
  io.rewind
  HTTP::Client::Response.from_io(io).body
end

private def playground(body : String) : {HTTP::Server::Context, String}
  context, io = create_context_with_remote_addr("POST", "/dev-dashboard/sql", "127.0.0.1", HTTP::Headers{"X-Requested-With" => "azu-dashboard"})
  context.request.body = IO::Memory.new(body)
  Azu::Handler::DevDashboard.new.call(context)
  {context, get_response_body(context, io)}
end

describe "Azu::CQL configuration" do
  store = Azu::QueryStore.instance
  original_uri = Azu::CONFIG.database.uri

  before_each do
    Azu::CQL::Instrumentor.uninstall
    store.clear
    store.adapter = nil
    File.delete?(DB_FILE)
  end

  after_all do
    Azu::CQL::Instrumentor.uninstall
    store.clear
    store.adapter = nil
    Azu::CONFIG.database.uri = original_uri
    ::CQL.reset_config!
    File.delete?(DB_FILE)
  end

  describe ".connection_url" do
    it "adds initial_pool_size=0 when lazy and leaves the rest of the URL alone" do
      Azu::CQL.connection_url("postgres://u@h/db").should eq "postgres://u@h/db?initial_pool_size=0"
      Azu::CQL.connection_url("sqlite3://./x.db").should eq "sqlite3://./x.db?initial_pool_size=0"
      Azu::CQL.connection_url("sqlite3:///abs/x.db").should eq "sqlite3:///abs/x.db?initial_pool_size=0"
      Azu::CQL.connection_url("sqlite3://:memory:").should eq "sqlite3://:memory:?initial_pool_size=0"
    end

    it "keeps the existing query and lets parameters on the URL win" do
      url = Azu::CQL.connection_url("postgres://u@h/db?sslmode=require&application_name=blog")
      URI.parse(url).query_params.to_h.should eq({"sslmode" => "require", "application_name" => "blog", "initial_pool_size" => "0"})

      Azu::CQL.connection_url("postgres://u@h/db?initial_pool_size=2").should eq "postgres://u@h/db?initial_pool_size=2"
    end

    it "is a no-op when eager and no pool settings apply" do
      Azu::CQL.connection_url("postgres://u@h/db", lazy: false).should eq "postgres://u@h/db"
    end

    it "applies CQL's pool settings only when asked, never over the URL" do
      config = ::CQL::Configure::Config.new
      config.pool.size = 7
      config.pool.max_idle_size = 3
      config.pool.checkout_timeout = 4.seconds

      params = URI.parse(Azu::CQL.connection_url("postgres://u@h/db", config, lazy: false, pool: true)).query_params
      params["max_pool_size"].should eq "7"
      params["max_idle_pool_size"].should eq "3"
      params["checkout_timeout"].should eq "4.0"
      params["initial_pool_size"].should eq config.pool.initial_size.to_s

      params = URI.parse(Azu::CQL.connection_url("postgres://u@h/db?max_pool_size=2", config, lazy: true, pool: true)).query_params
      params["max_pool_size"].should eq "2"
      params["initial_pool_size"].should eq "0"
    end
  end

  describe ".adapter_for" do
    it "maps every supported scheme and rejects the rest" do
      Azu::CQL.adapter_for("postgres://h/x").should eq ::CQL::Adapter::Postgres
      Azu::CQL.adapter_for("postgresql://h/x").should eq ::CQL::Adapter::Postgres
      Azu::CQL.adapter_for("mysql://h/x").should eq ::CQL::Adapter::MySql
      Azu::CQL.adapter_for("sqlite3://./x.db").should eq ::CQL::Adapter::SQLite
      expect_raises(ArgumentError, /Unsupported database URL scheme "oracle"/) { Azu::CQL.adapter_for("oracle://h/x") }
    end
  end

  describe ".schema" do
    it "prefers the uri argument, then CQL.config.db, then database.uri, and fails when none is set" do
      with_cql_config do
        explicit = Azu::CQL.schema(:explicit, "sqlite3://#{DB_FILE}") { }
        explicit.uri.should start_with "sqlite3://#{DB_FILE}"

        Azu::CQL.configure { |c| c.db = "sqlite3://#{DB_FILE}.configured" }
        configured = Azu::CQL.schema(:configured) { }
        configured.uri.should start_with "sqlite3://#{DB_FILE}.configured"
        configured.uri.should contain "max_pool_size="

        explicit_wins = Azu::CQL.schema(:explicit_wins, "sqlite3://#{DB_FILE}") { }
        explicit_wins.uri.should_not contain "max_pool_size="

        ::CQL.reset_config!
        Azu::CONFIG.database.uri = "sqlite3://#{DB_FILE}.fallback"
        Azu::CQL.schema(:fallback) { }.uri.should start_with "sqlite3://#{DB_FILE}.fallback"

        Azu::CONFIG.database.uri = nil
        expect_raises(ArgumentError, /needs a database URL/) { Azu::CQL.schema(:none) { } }
      end
    end

    it "attaches the dashboard and instruments queries" do
      with_cql_config do
        Azu::CQL.configure { |c| c.db = "sqlite3://#{DB_FILE}" }
        schema = Azu::CQL.schema :configured_app do
          table :things do
            primary :id, Int64
            column :name, String
          end
        end
        schema.build
        schema.exec("INSERT INTO things (name) VALUES ('x')")
        store.adapter.should_not be_nil
        store.queries.any? { |query| query.table == "things" && query.operation == "INSERT" }.should be_true
        store.adapter.not_nil!.dialect.should eq "sqlite"
      end
    end

    it "does not open a connection until the first query (lazy by default)" do
      schema = Azu::CQL.schema(:lazy_down, UNREACHABLE) { }
      schema.pool_stats.open.should eq 0
      expect_raises(DB::ConnectionRefused) { schema.exec("SELECT 1") }
    end

    it "connects eagerly with lazy: false or database.lazy_connect = false" do
      expect_raises(DB::ConnectionRefused) { Azu::CQL.schema(:eager_down, UNREACHABLE, lazy: false) { } }

      Azu::CONFIG.database.lazy_connect = false
      begin
        expect_raises(DB::ConnectionRefused) { Azu::CQL.schema(:eager_config, UNREACHABLE) { } }
      ensure
        Azu::CONFIG.database.lazy_connect = true
      end
    end
  end

  describe ".verify!" do
    it "returns a reachable schema and explains an unreachable one without leaking the password" do
      ok = Azu::CQL.schema(:ok, "sqlite3://#{DB_FILE}") { }
      Azu::CQL.verify!(ok).should eq ok

      down = Azu::CQL.schema(:down, UNREACHABLE) { }
      error = expect_raises(Azu::CQL::VerificationError, /Cannot reach the database/) { Azu::CQL.verify!(down) }
      error.message.to_s.should contain "***"
      error.message.to_s.should_not contain "secret"
    end
  end

  describe ".configure" do
    it "forwards to CQL.config and installs the instrumentation" do
      with_cql_config do
        Azu::CQL::Instrumentor.installed?.should be_false
        Azu::CQL.configure { |c| c.db = "sqlite3://#{DB_FILE}" }
        ::CQL.config.db.should eq "sqlite3://#{DB_FILE}"
        Azu::CQL.config.should be ::CQL.config
        Azu::CQL::Instrumentor.installed?.should be_true
      end
    end
  end

  describe ".attach with a block" do
    it "resolves a schema that is defined after the attach, once, and keeps the tab working before that" do
      late = nil.as(::CQL::Schema?)
      calls = 0
      Azu::CQL.attach do
        calls += 1
        late.not_nil!
      end
      adapter = store.adapter.not_nil!

      adapter.pool.should be_nil
      adapter.dialect.should eq "unknown"
      expect_raises(NilAssertionError) { adapter.read_only("SELECT 1", 1) }

      late = ::CQL::Schema.new(:late, "sqlite3://#{DB_FILE}", ::CQL::Adapter::SQLite)
      adapter.dialect.should eq "sqlite"
      adapter.pool.should_not be_nil
      adapter.read_only("SELECT 1 AS one", 1)[1].should eq [["1"]]
      calls_after_first_success = calls
      adapter.read_only("SELECT 2", 1)
      calls.should eq calls_after_first_success
    end
  end

  describe "the CQL event framework" do
    it "is the only way queries and transactions reach the dashboard" do
      with_cql_config do
        Azu::CQL.configure { |c| c.db = "sqlite3://#{DB_FILE}" } # no schema, no query: nothing but events can feed the store
        ::CQL::Events.subscribed?(::CQL::Events::QUERY).should be_true
        ::CQL::Events.subscribed?(::CQL::Events::TRANSACTION).should be_true
        ::CQL::Events.subscribed?(::CQL::Events::CONNECT).should be_true

        Azu::RequestContext.with("req-events", "GET", "/events", "EventsEndpoint") do
          ::CQL::Events.emit(::CQL::Events::TRANSACTION, ::CQL::Events::TransactionEvent.new(::CQL::Events::TransactionState::Begin, 9001_i64))
          ::CQL::Events.emit(::CQL::Events::QUERY, ::CQL::Events::QueryEvent.new("SELECT * FROM emitted_by_event WHERE id = $1", [1_i64.as(DB::Any)], 2.5, 1_i64))
          ::CQL::Events.emit(::CQL::Events::TRANSACTION, ::CQL::Events::TransactionEvent.new(::CQL::Events::TransactionState::Rollback, 9001_i64, 3.0))
        end

        metric = store.queries.find! { |query| query.table == "emitted_by_event" }
        metric.request_id.should eq "req-events"
        metric.endpoint.should eq "EventsEndpoint"
        metric.rows.should eq 1
        store.transactions.map(&.state).should eq ["rolled_back"]

        with_azu_env(Azu::Environment::Development) do
          html = dashboard
          html.should contain "emitted_by_event"
          html.should_not contain "CQL performance monitoring is not active"
        end

        Azu::CQL::Instrumentor.uninstall
        count = store.queries.size
        ::CQL::Events.emit(::CQL::Events::QUERY, ::CQL::Events::QueryEvent.new("SELECT 1 FROM after_uninstall", [] of DB::Any, 1.0))
        store.queries.size.should eq count
      end
    end
  end

  describe "the dashboard while the database is down" do
    it "renders the Database tab and reports the error from the playground" do
      down = Azu::CQL.schema(:dashboard_down, UNREACHABLE) { }
      Azu::CQL.attach(down)

      with_azu_env(Azu::Environment::Development) do
        html = dashboard
        ["N+1 analysis", "Recent queries", "Slow queries", "Query patterns", "Transactions", "Connection pool", "SQL playground"].each do |title|
          html.should contain title
        end

        context, body = playground(%({"sql":"SELECT 1","mode":"run"}))
        context.response.status_code.should eq 422
        body.should_not contain "secret"
        JSON.parse(body)["error"]?.should_not be_nil
      end
    end
  end
end

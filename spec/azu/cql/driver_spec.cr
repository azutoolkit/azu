require "../../spec_helper"
require "../../../src/azu/dev/dev"
require "sqlite3"
require "../../../src/azu/cql"

private def cql_config(&) : ::CQL::Configure::Config
  config = ::CQL::Configure::Config.new
  yield config
  config
end

private def query_of(url : String) : Hash(String, String)
  URI.parse(url).query_params.to_h
end

private ENGINE_UP = Azu::CQL::Driver::ENGINE_AVAILABLE

describe Azu::CQL::Driver do
  describe ".resolve" do
    it "defaults PostgreSQL URLs to the engine and everything else to crystal-db" do
      pending!("needs a CQL with CQL::Postgres::EngineSource") unless ENGINE_UP
      Azu::CQL::Driver.resolve("postgres://u@h/db").should eq Azu::CQL::Driver::Engine
      Azu::CQL::Driver.resolve("postgresql://u@h/db").should eq Azu::CQL::Driver::Engine
      Azu::CQL::Driver.resolve("cockroachdb://u@h/db").should eq Azu::CQL::Driver::Db
      Azu::CQL::Driver.resolve("mysql://u@h/db").should eq Azu::CQL::Driver::Db
      Azu::CQL::Driver.resolve("sqlite3://./x.db").should eq Azu::CQL::Driver::Db
    end

    it "lets the argument opt out, and opt CockroachDB in" do
      pending!("needs a CQL with CQL::Postgres::EngineSource") unless ENGINE_UP
      Azu::CQL::Driver.resolve("postgres://u@h/db", :db).should eq Azu::CQL::Driver::Db
      Azu::CQL::Driver.resolve("cockroachdb://u@h/db", :engine).should eq Azu::CQL::Driver::Engine
    end

    it "reads AZU_CQL_DRIVER (engine, db, or pg as an alias of db); the argument wins" do
      pending!("needs a CQL with CQL::Postgres::EngineSource") unless ENGINE_UP
      Azu::CQL::Driver.resolve("postgres://u@h/db", nil, "db").should eq Azu::CQL::Driver::Db
      Azu::CQL::Driver.resolve("postgres://u@h/db", nil, "pg").should eq Azu::CQL::Driver::Db
      Azu::CQL::Driver.resolve("postgres://u@h/db", nil, "Engine").should eq Azu::CQL::Driver::Engine
      Azu::CQL::Driver.resolve("cockroachdb://u@h/db", nil, "engine").should eq Azu::CQL::Driver::Engine
      Azu::CQL::Driver.resolve("postgres://u@h/db", :engine, "db").should eq Azu::CQL::Driver::Engine
      Azu::CQL::Driver.resolve("postgres://u@h/db", nil, "").should eq Azu::CQL::Driver::Engine
    end

    it "ignores a global engine setting for URLs the engine cannot serve, but refuses the argument there" do
      Azu::CQL::Driver.resolve("mysql://u@h/db", nil, "engine").should eq Azu::CQL::Driver::Db
      Azu::CQL::Driver.resolve("sqlite3://./x.db", nil, "engine").should eq Azu::CQL::Driver::Db
      expect_raises(ArgumentError, /not mysql/) { Azu::CQL::Driver.resolve("mysql://u@h/db", :engine) }
    end

    it "rejects an unknown driver name" do
      expect_raises(ArgumentError, /unknown CQL driver "fast"/) { Azu::CQL::Driver.resolve("postgres://u@h/db", nil, "fast") }
      expect_raises(ArgumentError, /unknown CQL driver/) { Azu::CQL::Driver.resolve("postgres://u@h/db", :fast) }
    end
  end
end

describe "Azu::CQL.engine_url" do
  it "drops what crystal-db owns and leaves a bare URL alone" do
    Azu::CQL.engine_url("postgres://u@h/db").should eq "postgres://u@h/db"
    url = Azu::CQL.engine_url("postgres://u@h/db?initial_pool_size=0&max_idle_pool_size=2&retry_attempts=3&retry_delay=1&prepared_statements=true&prepared_statements_cache=true&auth_methods=scram-sha-256&sslmode=require")
    query_of(url).should eq({"pool_min_size" => "0", "sslmode" => "require"})
  end

  it "renames max_pool_size and initial_pool_size, and an explicit pool_size wins" do
    query_of(Azu::CQL.engine_url("postgres://u@h/db?max_pool_size=7&initial_pool_size=2")).should eq({"pool_size" => "7", "pool_min_size" => "2"})
    query_of(Azu::CQL.engine_url("postgres://u@h/db?max_pool_size=7&pool_size=3")).should eq({"pool_size" => "3"})
    query_of(Azu::CQL.engine_url("postgres://u@h/db?initial_pool_size=2&pool_min_size=1")).should eq({"pool_min_size" => "1"})
  end

  it "adds CQL.config.pool when the URL came from the configuration" do
    config = cql_config do |c|
      c.pool.size = 12
      c.pool.checkout_timeout = 3.seconds
    end
    query_of(Azu::CQL.engine_url("postgres://u@h/db", config, lazy: true, pool: true)).should eq({"pool_size" => "12", "checkout_timeout" => "3.0"})
  end

  it "lets the URL win over the configuration" do
    config = cql_config { |c| c.pool.size = 12 }
    url = Azu::CQL.engine_url("postgres://u@h/db?max_pool_size=4&checkout_timeout=9", config, lazy: true, pool: true)
    query_of(url).should eq({"pool_size" => "4", "checkout_timeout" => "9"})
  end

  it "does not apply the configuration to a URL passed as the argument" do
    config = cql_config { |c| c.pool.size = 12 }
    Azu::CQL.engine_url("postgres://u@h/db", config, lazy: true, pool: false).should eq "postgres://u@h/db"
  end

  it "connects eagerly with pool_min_size: initial_size (at most pool_size) from the configuration, 1 for a plain URL" do
    config = cql_config do |c|
      c.pool.size = 4
      c.pool.initial_size = 2
    end
    query_of(Azu::CQL.engine_url("postgres://u@h/db", config, lazy: false, pool: true))["pool_min_size"].should eq "2"
    config.pool.initial_size = 4
    query_of(Azu::CQL.engine_url("postgres://u@h/db?max_pool_size=3", config, lazy: false, pool: true))["pool_min_size"].should eq "3"
    query_of(Azu::CQL.engine_url("postgres://u@h/db", config, lazy: false, pool: false)).should eq({"pool_min_size" => "1"})
  end

  it "turns prepared statements off with statement_cache_size=0 (poolers), unless the URL sets it" do
    config = cql_config { |c| c.pool.use_prepared_statements = false }
    query_of(Azu::CQL.engine_url("postgres://u@h/db", config, lazy: true, pool: true))["statement_cache_size"].should eq "0"
    query_of(Azu::CQL.engine_url("postgres://u@h/db?statement_cache_size=16", config, lazy: true, pool: true))["statement_cache_size"].should eq "16"
  end

  it "keeps the part before the query and the fragment" do
    Azu::CQL.engine_url("postgres://u:p%2Bw@h:5433/db?max_pool_size=2#frag").should eq "postgres://u:p%2Bw@h:5433/db?pool_size=2#frag"
    Azu::CQL.engine_url("postgres://u@h/db?initial_pool_size=0#frag").should eq "postgres://u@h/db?pool_min_size=0#frag"
  end
end

describe "Azu::CQL schema choice and lifecycle" do
  original_driver = Azu::CONFIG.database.driver

  after_each do
    Azu::CONFIG.database.driver = original_driver
  end

  after_all do
    Azu::CQL::Instrumentor.uninstall
    Azu::QueryStore.instance.adapter = nil
  end

  it "runs a PostgreSQL schema on the engine's pool, lazily, by default" do
    pending!("needs a CQL with CQL::Postgres::EngineSource") unless ENGINE_UP
    schema = Azu::CQL.schema(:driver_default, "postgres://u@127.0.0.1:1/db") { }
    schema.source.class.name.should eq "CQL::Postgres::EngineSource"
    Azu::CQL.engine(schema).should_not be_nil
    schema.pool_stats.open.should eq 0
    schema.close
  end

  it "keeps crystal-db's pool with driver: :db, with AZU_CQL_DRIVER=db, and for SQLite" do
    pending!("needs a CQL with CQL::Postgres::EngineSource") unless ENGINE_UP
    Azu::CQL.schema(:driver_db, "postgres://u@127.0.0.1:1/db", driver: :db) { }.source.should be_a ::CQL::DatabaseSource
    Azu::CONFIG.database.driver = "db"
    Azu::CQL.schema(:driver_env, "postgres://u@127.0.0.1:1/db") { }.source.should be_a ::CQL::DatabaseSource
    Azu::CONFIG.database.driver = nil
    sqlite = Azu::CQL.schema(:driver_sqlite, "sqlite3://#{File.join(Dir.tempdir, "azu_cql_driver_spec.db")}") { }
    sqlite.source.should be_a ::CQL::DatabaseSource
    Azu::CQL.engine(sqlite).should be_nil
  end

  it "refuses a driver the URL cannot use" do
    expect_raises(ArgumentError, /not sqlite3/) { Azu::CQL.schema(:driver_bad, "sqlite3://./x.db", driver: :engine) { } }
  end

  it "raises DB::ConnectionRefused from the engine path, lazily and eagerly" do
    pending!("needs a CQL with CQL::Postgres::EngineSource") unless ENGINE_UP
    url = "postgres://u@127.0.0.1:1/db"
    schema = Azu::CQL.schema(:driver_refused, url) { }
    expect_raises(DB::ConnectionRefused) { schema.exec("SELECT 1") }
    expect_raises(DB::ConnectionRefused) { Azu::CQL.schema(:driver_refused_eager, url, lazy: false) { } }
  end

  it "health_check is false when the database is down and true when it answers" do
    down = Azu::CQL.schema(:health_down, "postgres://u@127.0.0.1:1/db") { }
    Azu::CQL.health_check(down).call.should be_false
    up = Azu::CQL.schema(:health_up, "sqlite3://#{File.join(Dir.tempdir, "azu_cql_health_spec.db")}") { }
    Azu::CQL.health_check(up).call.should be_true
  end

  it "Azu.shutdown runs registered hooks and closes the schemas made through the bridge" do
    order = [] of String
    Azu.on_shutdown { order << "hook" }
    schema = Azu::CQL.schema(:shutdown_spec, "sqlite3://#{File.join(Dir.tempdir, "azu_cql_shutdown_spec.db")}") { }
    schema.with_connection { |connection| connection.scalar("SELECT 1") }
    Azu.shutdown
    order.should eq ["hook"]
    expect_raises(Exception) { schema.with_connection { |connection| connection.scalar("SELECT 1") } }
    Azu.shutdown # safe to call again
    order.should eq ["hook", "hook"]
  end
end

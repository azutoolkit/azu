require "../../spec_helper"
require "sqlite3"
require "../../../src/azu/cql"
require "../../../src/azu/dev/dev"

private DB_FILE = File.join(Dir.tempdir, "azu_cql_instrumentor_spec.db")

private def build_schema
  File.delete?(DB_FILE)
  schema = CQL::Schema.define(:azu_spec, adapter: CQL::Adapter::SQLite, uri: "sqlite3://#{DB_FILE}") do
    table :authors do
      primary :id, Int64
      column :name, String
    end
    table :books do
      primary :id, Int64
      column :author_id, Int64
      column :title, String
    end
  end
  schema.build
  schema
end

private class SpecServerError < Exception
end

private class SpecRollback < Exception
  include Azu::CQL::Instrumentor::IntentionalRollback
end

# Runs a fake statement through `CQL::Telemetry.observe`, the public path every CQL statement takes, so a spec can
# set what a SQLite flow cannot produce (a server's error text, an operation CQL labels itself, bound values).
private def publish_query(sql : String, params : Array(DB::Any) = [] of DB::Any, error : Exception? = nil, operation : Symbol = :select,
                          context : String? = nil) : Nil
  observe = -> do
    begin
      CQL::Telemetry.observe(CQL::Adapter::Postgres, operation, sql, params) { error ? raise(error) : nil }
    rescue ex
      raise ex unless ex.same?(error)
    end
  end
  context ? CQL::Telemetry.with_context(context) { observe.call } : observe.call
end

# A statement that waited for a pooled connection; only releases that measure the wait can report one.
private def publish_pool_wait(sql : String, wait : Time::Span) : Bool
  {% if ::CQL::Telemetry::QueryEvent.has_method?("pool_wait") %}
    event = CQL::Telemetry::QueryEvent.new(sql, 0, nil, 3.milliseconds, nil, CQL::Adapter::Postgres, :select, nil, nil, wait)
    CQL::Telemetry.publish(event)
    true
  {% else %}
    false
  {% end %}
end

describe Azu::CQL do
  store = Azu::QueryStore.instance

  before_each do
    Azu::CQL::Instrumentor.uninstall
    store.clear
  end
  after_all { Azu::CQL::Instrumentor.uninstall }

  it "records queries tagged with the current request" do
    schema = Azu::CQL.attach(build_schema)
    store.clear
    Azu::RequestContext.with("req-42", "GET", "/authors", "AuthorsEndpoint") do
      schema.exec("INSERT INTO authors (name) VALUES ('Ada')")
      schema.query.from(:authors).select(:name).all(String)
    end

    queries = store.queries
    insert = queries.find! { |q| q.operation == "INSERT" }
    insert.request_id.should eq "req-42"
    insert.endpoint.should eq "AuthorsEndpoint"
    insert.path.should eq "/authors"
    insert.table.should eq "authors"
    insert.caller.to_s.should contain "instrumentor_spec.cr"
    select_q = queries.find! { |q| q.operation == "SELECT" }
    insert.rows.should eq 1 # CQL::Telemetry reports rows_affected for DML only
    select_q.rows.should be_nil
    select_q.duration_ms.should be >= 0
    Azu::CQL::Instrumentor.installed?.should be_true
  end

  it "flags an N+1 loop but not an eager query" do
    schema = Azu::CQL.attach(build_schema)
    3.times { |i| schema.exec("INSERT INTO authors (name) VALUES ('a#{i}')") }
    3.times { |i| schema.exec("INSERT INTO books (author_id, title) VALUES (#{i + 1}, 't')") }
    store.clear

    Azu::RequestContext.with("req-n1", "GET", "/books") do
      ids = schema.query.from(:authors).select(:id).all(Int64)
      ids.each { |id| schema.query.from(:books).select(:id, :title).where(author_id: id).all({id: Int64, title: String}) }
    end
    alerts = store.n_plus_one(3)
    alerts.size.should eq 1
    alerts.first.request_id.should eq "req-n1"
    alerts.first.count.should eq 3

    store.clear
    Azu::RequestContext.with("req-ok", "GET", "/books") do
      schema.query.from(:books).select(:id, :title).all({id: Int64, title: String})
    end
    store.n_plus_one(3).should be_empty
  end

  it "records committed and rolled back transactions with their queries" do
    schema = Azu::CQL.attach(build_schema)
    store.clear
    schema.transaction { |_tx| schema.exec("INSERT INTO authors (name) VALUES ('ok')") }
    schema.transaction do |_tx|
      schema.exec("INSERT INTO authors (name) VALUES ('nope')")
      raise DB::Rollback.new
    end

    states = store.transactions.map(&.state)
    states.should eq ["rolled_back", "committed"]
    store.transactions.map(&.query_count).should eq [1, 1]
    store.queries.map(&.transaction_id).compact.size.should eq 2
  end

  it "exposes pool stats and the playground adapter" do
    schema = Azu::CQL.attach(build_schema)
    schema.exec("INSERT INTO authors (name) VALUES ('Grace')")
    store.pool.should_not be_nil
    adapter = store.adapter.not_nil!
    adapter.dialect.should eq "sqlite"
    columns, rows = adapter.read_only("SELECT name FROM authors", 10)
    columns.should eq ["name"]
    rows.should eq [["Grace"]]
    adapter.read_only("SELECT count(*) FROM authors", 10)[1].size.should eq 1
  end

  it "records placeholders, never bound values, even when the app turned on CQL's capture_params" do
    schema = Azu::CQL.attach(build_schema)
    store.clear
    ::CQL::Telemetry.capture_params = true
    begin
      schema.insert.into(:authors).values(name: "hunter2-secret").commit
      schema.query.from(:authors).select(:id).where(name: "hunter2-secret").all(Int64)
    ensure
      ::CQL::Telemetry.capture_params = false
    end

    store.queries.size.should eq 2
    store.queries.each do |metric|
      metric.params.should eq ["?"]
      metric.to_json.should_not contain "hunter2"
    end
  end

  it "does not show a deliberate rollback as an error, but keeps the error of a failed transaction" do
    schema = Azu::CQL.attach(build_schema)
    store.clear
    schema.transaction { |_tx| raise DB::Rollback.new }
    expect_raises(Exception) { schema.transaction { |_tx| schema.exec("INSERT INTO missing_table (x) VALUES (1)") } }

    failed, deliberate = store.transactions
    deliberate.state.should eq "rolled_back"
    deliberate.error.should be_nil
    failed.state.should eq "rolled_back"
    failed.error.to_s.should contain "missing_table"
  end

  it "reinstalls the transaction subscriber after only that one was removed" do
    schema = Azu::CQL.attach(build_schema)
    ::CQL::Telemetry.unsubscribe_transactions(Azu::CQL::Instrumentor::NAME)
    Azu::CQL::Instrumentor.install
    store.clear

    schema.transaction { |_tx| schema.exec("INSERT INTO authors (name) VALUES ('x')") }

    store.transactions.map(&.state).should eq ["committed"]
  end

  describe "bound values" do
    after_each do
      Azu::CONFIG.database.show_params = false
      ::CQL::Telemetry.capture_params = false
    end

    it "shows them only when database.show_params is on in development, and has CQL capture them for it" do
      Azu::CONFIG.database.show_params = true
      with_azu_env(Azu::Environment::Development) do
        Azu::CQL::Instrumentor.install
        ::CQL::Telemetry.capture_params.should be_true
        schema = Azu::CQL.attach(build_schema)
        store.clear
        schema.insert.into(:authors).values(name: "visible-name").commit

        metric = store.queries.first
        metric.params.should eq [%("visible-name")]
        metric.params_shown?.should be_true

        Azu::CQL::Instrumentor.uninstall
        ::CQL::Telemetry.capture_params.should be_false
      end
    end

    it "ignores show_params outside development" do
      Azu::CONFIG.database.show_params = true
      with_azu_env(Azu::Environment::Production) do
        Azu::CQL::Instrumentor.install
        ::CQL::Telemetry.capture_params.should be_false
        ::CQL::Telemetry.capture_params = true # the app's own switch
        schema = Azu::CQL.attach(build_schema)
        store.clear
        schema.insert.into(:authors).values(name: "hidden-name").commit

        store.queries.first.params.should eq ["?"]
      end
    end

    it "summarizes binary values and truncates long ones" do
      Azu::CONFIG.database.show_params = true
      with_azu_env(Azu::Environment::Development) do
        Azu::CQL::Instrumentor.install
        publish_query("INSERT INTO blobs (data, note) VALUES (?, ?)", [Bytes.new(2048), "x" * 500] of DB::Any, operation: :insert)

        store.queries.first.params.first.should eq "<2048 bytes>"
        store.queries.first.params.last.size.should be <= 202
      end
    end

    it "keeps values out of error text unless they are shown" do
      Azu::CQL::Instrumentor.install
      server_error = Exception.new("duplicate key value violates unique constraint \"u\"\nDETAIL: Key (email)=(ada@example.com) already exists.")
      publish_query("INSERT INTO users (email) VALUES ($1)", error: server_error, operation: :insert)
      mysql_error = Exception.new("Duplicate entry 'grace@example.com' for key 'email'")
      publish_query("INSERT INTO users (email) VALUES (?)", error: mysql_error, operation: :insert)

      store.queries.each { |metric| metric.error.to_s.should_not contain "example.com" }
      store.queries.first.error.to_s.should contain "duplicate key value violates unique constraint"

      Azu::CONFIG.database.show_params = true
      with_azu_env(Azu::Environment::Development) do
        store.clear
        publish_query("INSERT INTO users (email) VALUES ($1)", error: server_error, operation: :insert)
        store.queries.first.error.to_s.should contain "ada@example.com"
      end
    end
  end

  it "keeps values quoted by a database server out of every card that shows an error" do
    Azu::CQL::Instrumentor.install
    errors = [
      "duplicate key value violates unique constraint \"u\"\nDETAIL: Key (email)=(SECRET-1@example.com) already exists.",
      "new row violates check constraint \"c\"\nDETAIL: Failing row contains (1, SECRET-2, hunter2).",
      %(invalid input value for enum status: "SECRET-3"),
      %(date/time field value out of range: "SECRET-4"),
      %(value "SECRET-5" is out of range for type integer),
      "invalid input syntax for type json\nDETAIL: Token \"SECRET-6\" is invalid.\nCONTEXT: JSON data, line 1: {SECRET-6",
      "Incorrect integer value: 'SECRET-7' for column 'age' at row 1",
      "Duplicate entry 'a\nSECRET-8' for key 'users.email'",
      "Key (note)=(line1\nline2-SECRET-9) already exists.",
    ]
    previous = Azu::CONFIG.database.slow_query_ms
    Azu::CONFIG.database.slow_query_ms = 0.0
    begin
      errors.each do |message|
        publish_query("INSERT INTO users (email) VALUES ($1)", error: SpecServerError.new(message), operation: :insert)
        observer = CQL::Telemetry.begin_transaction(CQL::Adapter::Postgres, false).not_nil!
        observer.failed(SpecServerError.new(message))
        observer.finish
      end

      html = Azu::Components::DevDashboardComponent.new(Azu::PerformanceMetrics.new).render
      html.should contain "Recent queries"
      html.should contain "Slow queries"
      html.should contain "Transactions"
      html.should contain "duplicate key value violates unique constraint"
      html.scan(/SECRET|hunter2|example\.com/).should be_empty
    ensure
      Azu::CONFIG.database.slow_query_ms = previous
    end
  end

  it "gives capture_params back as the app had it when the instrumentor is removed" do
    ::CQL::Telemetry.capture_params = true # the app's own tracing
    Azu::CONFIG.database.show_params = true
    begin
      with_azu_env(Azu::Environment::Development) do
        Azu::CQL::Instrumentor.install
        Azu::CQL::Instrumentor.install
        Azu::CQL::Instrumentor.uninstall
      end
      ::CQL::Telemetry.capture_params.should be_true
    ensure
      Azu::CONFIG.database.show_params = false
      ::CQL::Telemetry.capture_params = false
    end
  end

  it "labels statements with CQL's operation, and falls back to the SQL for raw exec" do
    schema = Azu::CQL.attach(build_schema)
    store.clear
    schema.insert.into(:authors).values(name: "a").commit
    schema.exec("INSERT INTO authors (name) VALUES ('raw')")
    publish_query("(SELECT id FROM authors) UNION (SELECT id FROM books)")
    publish_query("WITH moved AS (UPDATE authors SET name = 'x' RETURNING id) SELECT id FROM moved", operation: :update)

    store.queries.map(&.operation).should eq ["INSERT", "INSERT", "SELECT", "UPDATE"]
    store.queries.map(&.adapter).uniq!.should eq ["SQLite", "Postgres"]
  end

  it "records the telemetry context, the pool wait and the adapter" do
    Azu::CQL::Instrumentor.install
    publish_query("SELECT 1", context: "job:nightly")
    if publish_pool_wait("SELECT 2", 12.milliseconds)
      store.queries.last.pool_wait_ms.should eq 12.0
    end
    schema = Azu::CQL.attach(build_schema)
    ::CQL::Telemetry.with_context("request:42") { schema.exec("SELECT 1") }

    store.queries.first.context.should eq "job:nightly"
    store.queries.first.pool_wait_ms.should eq 0.0
    store.queries.last.context.should eq "request:42"
  end

  it "attributes statements to the nested transaction they ran in and back to the outer one after it" do
    schema = Azu::CQL.attach(build_schema)
    store.clear
    begin
      schema.transaction do |_tx|
        schema.exec("INSERT INTO authors (name) VALUES ('outer')")
        schema.transaction do |_inner|
          schema.exec("INSERT INTO authors (name) VALUES ('inner')")
          raise DB::Rollback.new
        end
        schema.exec("INSERT INTO authors (name) VALUES ('outer again')")
      end
    rescue ex : SQLite3::Exception
      # CQL before 0.0.626 ran a nested transaction on a second connection, which SQLite refuses (database is locked)
      pending!("CQL #{ex.message}: nested transactions are savepoints from 0.0.626")
    end

    outer, inner = store.transactions.sort_by(&.id)
    outer.nested.should be_false
    inner.nested.should be_true
    inner.state.should eq "rolled_back"
    outer.state.should eq "committed"
    by_name = store.queries.to_h { |metric| {metric.sql[/VALUES \('(.*)'\)/, 1], metric.transaction_id} }
    by_name["outer"].should eq outer.id
    by_name["inner"].should eq inner.id
    by_name["outer again"].should eq outer.id
    outer.query_count.should eq 2
    inner.query_count.should eq 1
  end

  it "does not show an exception marked as an intentional rollback as an error" do
    Azu::CQL::Instrumentor.install
    observer = CQL::Telemetry.begin_transaction(CQL::Adapter::SQLite, false).not_nil!
    observer.failed(SpecRollback.new("status 404"))
    observer.finish

    store.transactions.first.state.should eq "rolled_back"
    store.transactions.first.error.should be_nil
  end

  it "describes the connection source of the attached schema" do
    adapter = Azu::CQL::SchemaAdapter.new(build_schema)
    adapter.adapter_name.should eq "SQLite"
    adapter.connection_source.should eq "crystal-db pool"
  end

  it "honours database.instrument = false" do
    schema = Azu::CQL.attach(build_schema)
    store.clear
    Azu::CONFIG.database.instrument = false
    begin
      schema.exec("SELECT 1")
      store.queries.should be_empty
    ensure
      Azu::CONFIG.database.instrument = true
    end
  end

  it "treats framework and driver frames as internal but keeps app code, even under a `crystal` directory" do
    internal = Azu::CQL::Instrumentor
    internal.internal_frame?("lib/cql/src/schema.cr:259").should be_true
    internal.internal_frame?("/usr/share/crystal/src/db/query_methods.cr:10").should be_true
    internal.internal_frame?("lib/pg/src/pg/statement.cr:37").should be_true
    internal.internal_frame?("/root/.cache/crystal/crystal-run-spec.tmp").should be_true
    internal.internal_frame?("??").should be_true

    internal.internal_frame?("/home/dev/crystal/blog/src/endpoints/users.cr:12").should be_false
    internal.internal_frame?("src/endpoints/users.cr:12").should be_false
  end

  it "picks the adapter from the uri" do
    Azu::CQL.adapter_for("postgres://localhost/x").should eq CQL::Adapter::Postgres
    Azu::CQL.adapter_for("sqlite3://./x.db").should eq CQL::Adapter::SQLite
    Azu::CQL.adapter_for("cockroachdb://root@localhost:26257/x").should eq CQL::Adapter::CockroachDB
  end

  it "reports CockroachDB as a postgres dialect for EXPLAIN" do
    schema = ::CQL::Schema.new(:crdb_spec, "cockroachdb://root@127.0.0.1:1/x?initial_pool_size=0", ::CQL::Adapter::CockroachDB)
    Azu::CQL::SchemaAdapter.new(schema).dialect.should eq "postgres"
  end

  it "survives CQL::Telemetry.reset! by reinstalling" do
    Azu::CQL::Instrumentor.install
    ::CQL::Telemetry.reset!
    Azu::CQL::Instrumentor.installed?.should be_false
    Azu::CQL::Instrumentor.install
    Azu::CQL::Instrumentor.installed?.should be_true
  end
  it "defines a schema from a uri and attaches it" do
    File.delete?(DB_FILE)
    schema = Azu::CQL.schema(:azu_spec_zero_config, "sqlite3://#{DB_FILE}") do
      table :things do
        primary :id, Int64
        column :name, String
      end
    end
    schema.build
    Azu::CQL::Instrumentor.installed?.should be_true
    store.adapter.should_not be_nil
    schema.exec("INSERT INTO things (name) VALUES ('x')")
    store.queries.any? { |query| query.table == "things" }.should be_true
  end

  it "keeps CQL types resolvable when Azu is included in an app namespace" do
    # CQL's own macros expand `CQL::ActiveRecord::...` inside the app's namespace
    Azu::CQL::ActiveRecord::Model.should eq ::CQL::ActiveRecord::Model
    Azu::CQL::Schema.should eq ::CQL::Schema
    Azu::CQL::Adapter::SQLite.should eq ::CQL::Adapter::SQLite
  end
end

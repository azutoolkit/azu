require "../../spec_helper"
require "../../support/postgres"
require "../../support/integration_helpers"
require "../../../src/azu/cql"

include IntegrationHelpers

# The CQL bridge against a real PostgreSQL: CQL's Postgres dialect ($n placeholders, RETURNING,
# identity keys), real transactions and pool counters, and the dashboard playground's EXPLAIN.
module BridgePostgresSpec
  def self.schema : CQL::Schema
    Azu::CQL.schema(:bridge_pg, PostgresSpec.url) do
      table :bridge_authors do
        primary :id, Int64
        column :name, String
      end
      table :bridge_books do
        primary :id, Int64
        column :author_id, Int64
        column :title, String
      end
    end
  end

  def self.rebuild : CQL::Schema
    schema = self.schema
    schema.exec("DROP TABLE IF EXISTS bridge_books")
    schema.exec("DROP TABLE IF EXISTS bridge_authors")
    schema.build
    schema
  end

  def self.seed(schema : CQL::Schema, authors = 3)
    authors.times do |i|
      schema.exec("INSERT INTO bridge_authors (name) VALUES ('author #{i}')")
      schema.exec("INSERT INTO bridge_books (author_id, title) VALUES (#{i + 1}, 'book #{i}')")
    end
  end

  def self.dashboard(path : String = "/dev-dashboard") : String
    context, io = create_context("GET", path)
    Azu::Handler::DevDashboard.new.call(context)
    context.response.close
    io.rewind
    HTTP::Client::Response.from_io(io).body
  end

  def self.playground(body : String) : {HTTP::Server::Context, String}
    context, io = create_context_with_remote_addr("POST", "/dev-dashboard/sql", "127.0.0.1", HTTP::Headers{"X-Requested-With" => "azu-dashboard"})
    context.request.body = IO::Memory.new(body)
    Azu::Handler::DevDashboard.new.call(context)
    {context, get_response_body(context, io)}
  end
end

describe "Azu::CQL bridge on PostgreSQL" do
  store = Azu::QueryStore.instance

  before_each do
    Azu::CQL::Instrumentor.uninstall
    store.clear
    store.adapter = nil
  end
  after_all do
    Azu::CQL::Instrumentor.uninstall
    store.clear
    store.adapter = nil
  end

  it "builds the schema, attaches the adapter and reports pool counters" do
    PostgresSpec.require!
    BridgePostgresSpec.rebuild
    Azu::CQL::Instrumentor.installed?.should be_true
    adapter = store.adapter.not_nil!
    adapter.dialect.should eq "postgres"

    pool = store.pool.not_nil!
    pool.open.should be >= 1
    pool.idle.should be <= pool.open
    pool.in_flight.should eq 0
  end

  it "records statements with Postgres placeholders, rows, timing and the request" do
    PostgresSpec.require!
    schema = BridgePostgresSpec.rebuild
    store.clear

    Azu::RequestContext.with("req-pg-1", "GET", "/authors", "AuthorsEndpoint") do
      schema.exec("INSERT INTO bridge_authors (name) VALUES ('Ada'), ('Grace')")
      schema.query.from(:bridge_authors).select(:name).where(name: "Ada").all(String)
    end

    queries = store.queries
    insert = queries.find! { |query| query.operation == "INSERT" }
    insert.table.should eq "bridge_authors"
    insert.request_id.should eq "req-pg-1"
    insert.endpoint.should eq "AuthorsEndpoint"

    select_query = queries.find! { |query| query.operation == "SELECT" }
    select_query.sql.should contain "$1"
    select_query.normalized_sql.should contain "= ?"
    select_query.params.should eq ["?"] # values only with CQL::Telemetry.capture_params
    select_query.rows.should be_nil     # Telemetry reports rows_affected for DML only
    select_query.duration_ms.should be > 0
    select_query.caller.to_s.should contain "bridge_postgres_spec.cr"
  end

  it "records a failing statement with the server's error" do
    PostgresSpec.require!
    schema = BridgePostgresSpec.rebuild
    store.clear
    expect_raises(Exception) { schema.exec("SELECT * FROM bridge_missing_table") }
    failed = store.queries.last
    failed.error?.should be_true
    failed.error.to_s.should contain "bridge_missing_table"
  end

  it "groups an N+1 loop despite per-call $n placeholders, and not an eager query" do
    PostgresSpec.require!
    schema = BridgePostgresSpec.rebuild
    BridgePostgresSpec.seed(schema)
    store.clear

    Azu::RequestContext.with("req-pg-n1", "GET", "/books", "BooksEndpoint") do
      schema.query.from(:bridge_authors).select(:id).all(Int64).each do |id|
        schema.query.from(:bridge_books).select(:title).where(author_id: id).all(String)
      end
    end
    alerts = store.n_plus_one(3)
    alerts.size.should eq 1
    alerts.first.count.should eq 3
    alerts.first.request_id.should eq "req-pg-n1"
    alerts.first.table.should eq "bridge_books"

    store.clear
    Azu::RequestContext.with("req-pg-ok", "GET", "/books") do
      schema.query.from(:bridge_books).select(:title).all(String)
    end
    store.n_plus_one(3).should be_empty
  end

  it "records committed and rolled back transactions with their statements" do
    PostgresSpec.require!
    schema = BridgePostgresSpec.rebuild
    store.clear

    schema.transaction { |_tx| schema.exec("INSERT INTO bridge_authors (name) VALUES ('kept')") }
    schema.transaction do |_tx|
      schema.exec("INSERT INTO bridge_authors (name) VALUES ('discarded')")
      raise DB::Rollback.new
    end
    expect_raises(Exception, "boom") do
      schema.transaction do |_tx|
        schema.exec("INSERT INTO bridge_authors (name) VALUES ('boom')")
        raise "boom"
      end
    end

    store.transactions.map(&.state).should eq ["rolled_back", "rolled_back", "committed"]
    store.transactions.map(&.query_count).should eq [1, 1, 1]
    store.adapter.not_nil!.read_only("SELECT name FROM bridge_authors ORDER BY id", 10)[1].should eq [["kept"]]
  end

  it "runs playground statements read-only and rolls back even a data-modifying CTE" do
    PostgresSpec.require!
    schema = BridgePostgresSpec.rebuild
    BridgePostgresSpec.seed(schema, 2)
    adapter = store.adapter.not_nil!

    columns, rows = adapter.read_only("SELECT id, name FROM bridge_authors ORDER BY id", 10)
    columns.should eq ["id", "name"]
    rows.should eq [["1", "author 0"], ["2", "author 1"]]

    # Bypasses the validator on purpose: the transaction itself must still be rolled back.
    adapter.read_only("WITH gone AS (DELETE FROM bridge_authors RETURNING *) SELECT count(*)::text FROM gone", 1)[1].should eq [["2"]]
    adapter.read_only("SELECT count(*)::text FROM bridge_authors", 1)[1].should eq [["2"]]
  end

  it "explains and explain-analyzes through the dashboard endpoint" do
    PostgresSpec.require!
    BridgePostgresSpec.rebuild
    with_azu_env(Azu::Environment::Development) do
      plain, body = BridgePostgresSpec.playground(%({"sql":"SELECT * FROM bridge_authors WHERE id = 1","mode":"explain"}))
      plain.response.status_code.should eq 200
      JSON.parse(body)["columns"].as_a.map(&.as_s).should eq ["QUERY PLAN"]
      JSON.parse(body)["rows"].as_a.map(&.[0].as_s).join("\n").should contain "bridge_authors"

      analyzed, body = BridgePostgresSpec.playground(%({"sql":"SELECT * FROM bridge_authors","mode":"explain_analyze"}))
      analyzed.response.status_code.should eq 200
      plan = JSON.parse(body)["rows"].as_a.map(&.[0].as_s).join("\n")
      plan.should contain "Execution Time"
      plan.should contain "Buffers"

      refused, _ = BridgePostgresSpec.playground(%({"sql":"DELETE FROM bridge_authors","mode":"explain_analyze"}))
      refused.response.status_code.should eq 400
    end
  end

  it "renders the Database tab from Postgres-backed queries" do
    PostgresSpec.require!
    schema = BridgePostgresSpec.rebuild
    BridgePostgresSpec.seed(schema)
    store.clear

    Azu::RequestContext.with("req-pg-ui", "GET", "/books", "BooksEndpoint") do
      schema.query.from(:bridge_authors).select(:id).all(Int64).each do |id|
        schema.query.from(:bridge_books).select(:title).where(author_id: id).all(String)
      end
    end
    schema.transaction { |_tx| schema.exec("UPDATE bridge_authors SET name = 'renamed' WHERE id = 1") }

    with_azu_env(Azu::Environment::Development) do
      html = BridgePostgresSpec.dashboard
      html.should contain "Recent queries"
      html.should contain "bridge_books"
      html.should contain "N+1 analysis"
      html.should contain "3x SELECT"
      html.should contain "BooksEndpoint"
      html.should contain "committed"
      html.should contain "Connection pool"
      html.should contain "id='azd-sql'"
    end
  end
end

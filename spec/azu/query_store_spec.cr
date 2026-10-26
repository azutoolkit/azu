require "../spec_helper"
require "log/spec"

private def add_query(store : Azu::QueryStore, sql : String, request_id : String? = "req-1", duration_ms = 1.0, tx : Int64? = nil, error : String? = nil)
  store.record_query(sql, [] of String, duration_ms, 1_i64, error, "src/app.cr:10", tx, request_id, "UsersEndpoint", "GET", "/users", 1_u64)
end

describe Azu::QueryAnalysis do
  it "normalizes literals, bindings and IN lists" do
    Azu::QueryAnalysis.normalize("SELECT * FROM posts WHERE user_id = 42 AND title = 'it''s' AND id IN (1, 2, 3)")
      .should eq "SELECT * FROM posts WHERE user_id = ? AND title = ? AND id IN (?)"
    Azu::QueryAnalysis.normalize("SELECT *\n  FROM posts WHERE id = $1").should eq "SELECT * FROM posts WHERE id = ?"
    Azu::QueryAnalysis.normalize("SELECT * FROM t1 WHERE id = ?").should eq "SELECT * FROM t1 WHERE id = ?"
  end

  it "extracts operation and table" do
    Azu::QueryAnalysis.operation("  select 1").should eq "SELECT"
    Azu::QueryAnalysis.table("SELECT * FROM \"posts\" WHERE 1").should eq "posts"
    Azu::QueryAnalysis.table("INSERT INTO users (a) VALUES (1)").should eq "users"
    Azu::QueryAnalysis.table("UPDATE users SET a = 1").should eq "users"
  end

  describe ".read_only?" do
    it "accepts single read statements" do
      Azu::QueryAnalysis.read_only?("SELECT * FROM users;").should be_true
      Azu::QueryAnalysis.read_only?("WITH x AS (SELECT 1) SELECT * FROM x").should be_true
      Azu::QueryAnalysis.read_only?("EXPLAIN SELECT 1").should be_true
      Azu::QueryAnalysis.read_only?("SELECT * FROM posts WHERE title = 'delete; me'").should be_true
      Azu::QueryAnalysis.read_only?("SELECT updated_at FROM posts").should be_true
    end

    it "rejects writes, multiple statements and comments" do
      Azu::QueryAnalysis.read_only?("DELETE FROM users").should be_false
      Azu::QueryAnalysis.read_only?("SELECT 1; DROP TABLE users").should be_false
      Azu::QueryAnalysis.read_only?("SELECT 1 -- hi").should be_false
      Azu::QueryAnalysis.read_only?("SELECT 1 /* x */").should be_false
      Azu::QueryAnalysis.read_only?("WITH d AS (DELETE FROM users RETURNING *) SELECT * FROM d").should be_false
      Azu::QueryAnalysis.read_only?("PRAGMA writable_schema = 1").should be_false
      Azu::QueryAnalysis.read_only?("").should be_false
    end
  end
end

describe "Azu::QueryAnalysis.redact_error" do
  # Every shape a server quotes a data value in, as seen in PostgreSQL, MySQL and SQLite messages.
  shapes = {
    "unique detail"       => "duplicate key value violates unique constraint \"u\"\nDETAIL: Key (email)=(SECRET@example.com) already exists.",
    "key on one line"     => "duplicate key value violates unique constraint \"u\" DETAIL: Key (email)=(SECRET) already exists.",
    "key alone"           => "Key (email)=(SECRET) already exists.",
    "key multi-line"      => "Key (note)=(line1\nline2-SECRET) already exists.",
    "failing row"         => "new row for relation \"users\" violates check constraint \"c\"\nDETAIL: Failing row contains (1, SECRET@example.com, SECRET).",
    "failing row inline"  => "Failing row contains (1, SECRET, SECRET).",
    "invalid syntax"      => %(invalid input syntax for type integer: "SECRET"),
    "invalid enum"        => %(invalid input value for enum status: "SECRET"),
    "datetime"            => %(date/time field value out of range: "SECRET"),
    "out of range"        => %(value "SECRET" is out of range for type integer),
    "json token"          => "invalid input syntax for type json\nDETAIL: Token \"SECRET\" is invalid.\nCONTEXT: JSON data, line 1: {\"a\": SECRET",
    "mysql duplicate"     => "Duplicate entry 'SECRET@example.com' for key 'users.email'",
    "mysql duplicate nl"  => "Duplicate entry 'a\nSECRET' for key 'users.email'",
    "mysql incorrect"     => "Incorrect integer value: 'SECRET' for column 'age' at row 1",
    "single quotes"       => "bad value 'SECRET' here",
    "unterminated double" => "bad value \"SECRET\nmore",
    "hint"                => "something failed\nHINT: use SECRET",
  }

  shapes.each do |name, message|
    it "keeps the value out of #{name}" do
      Azu::QueryAnalysis.redact_error(message).should_not contain "SECRET"
      Azu::QueryAnalysis.redact_error(message).should_not contain "example.com"
    end
  end

  it "keeps the first line, and the names it can keep without values" do
    redact = ->(message : String) { Azu::QueryAnalysis.redact_error(message) }
    redact.call("duplicate key value violates unique constraint \"users_email_key\"\nDETAIL: Key (email)=(a@b.c) already exists.").should eq "duplicate key value violates unique constraint \"users_email_key\""
    redact.call("Key (email)=(a@b.c) already exists.").should eq "Key (email)=(…)"
    redact.call("Incorrect integer value: 'x' for column 'age' at row 1").should eq "Incorrect integer value: '…' for column 'age' at row 1"
    redact.call("Duplicate entry 'a@b.c' for key 'users.email'").should eq "Duplicate entry '…' for key 'users.email'"
    redact.call("relation \"users\" does not exist").should eq "relation \"users\" does not exist"
    redact.call("no such table: users").should eq "no such table: users"
    redact.call("UNIQUE constraint failed: users.email").should eq "UNIQUE constraint failed: users.email"
  end
end

describe Azu::QueryStore do
  it "assigns increasing ids and filters by since" do
    store = Azu::QueryStore.new
    a = add_query(store, "SELECT 1")
    b = add_query(store, "SELECT 2")
    b.id.should be > a.id
    store.queries(a.id).map(&.sql).should eq ["SELECT 2"]
    store.last_id.should eq b.id
  end

  it "warns about statements at or over database.slow_query_ms, naming the endpoint" do
    store = Azu::QueryStore.new
    original = Azu::CONFIG.database.slow_query_ms
    Azu::CONFIG.database.slow_query_ms = 50.0
    begin
      Log.capture("Azu") do |logs|
        add_query(store, "SELECT 1", duration_ms: 49.9)
        add_query(store, "SELECT *\n  FROM posts", duration_ms: 120.0)
        logs.check(:warn, /Slow query \(120\.0ms, limit 50\.0ms\) in UsersEndpoint: SELECT \* FROM posts/)
        logs.empty
      end

      Azu::CONFIG.database.slow_query_ms = 0.0
      Log.capture("Azu") do |logs|
        add_query(store, "SELECT 1", duration_ms: 5000.0)
        logs.empty
      end
    ensure
      Azu::CONFIG.database.slow_query_ms = original
    end
  end

  it "keeps a bounded history" do
    store = Azu::QueryStore.new
    (Azu::QueryStore::MAX_QUERIES + 25).times { |i| add_query(store, "SELECT #{i}") }
    store.queries(0_i64, Azu::QueryStore::MAX_QUERIES + 100).size.should eq Azu::QueryStore::MAX_QUERIES
  end

  it "detects N+1 only for repeated SELECT shapes within one request" do
    store = Azu::QueryStore.new
    5.times { |i| add_query(store, "SELECT * FROM posts WHERE posts.user_id = #{i}") }
    2.times { |i| add_query(store, "SELECT * FROM users WHERE id = #{i}") }
    3.times { |i| add_query(store, "SELECT * FROM posts WHERE posts.user_id = #{i}", request_id: "req-2") }
    5.times { |i| add_query(store, "INSERT INTO logs (a) VALUES (#{i})") }

    alerts = store.n_plus_one(3)
    alerts.size.should eq 2
    alerts.first.count.should eq 5
    alerts.first.request_id.should eq "req-1"
    alerts.first.table.should eq "posts"
    alerts.first.caller.should eq "src/app.cr:10"
    alerts.first.suggestion.to_s.should contain "preload(:posts)"
    store.n_plus_one(6).should be_empty
  end

  it "tracks transaction lifecycle and query counts" do
    store = Azu::QueryStore.new
    store.record_transaction_begin(7_i64, false, "req-1", "UsersEndpoint")
    store.transactions.first.state.should eq "open"
    add_query(store, "UPDATE a SET b = 1", tx: 7_i64)
    store.record_transaction_end(7_i64, false, 3.5, "boom")
    tx = store.transactions.first
    tx.state.should eq "rolled_back"
    tx.query_count.should eq 1
    tx.error.should eq "boom"
  end

  it "clears everything" do
    store = Azu::QueryStore.new
    add_query(store, "SELECT 1")
    store.record_transaction_begin(1_i64, false, nil, nil)
    store.clear
    store.queries.should be_empty
    store.transactions.should be_empty
  end
end

describe Azu::QueryMetric do
  it "keeps the new fields optional when recording and when reading older JSON" do
    store = Azu::QueryStore.new
    plain = store.record_query("SELECT 1", ["?"], 1.0, nil, nil, nil, nil, nil, nil, nil, nil, 1_u64)
    plain.pool_wait_ms.should eq 0.0
    plain.context.should be_nil
    plain.operation.should eq "SELECT"

    full = store.record_query("(SELECT 1)", [] of String, 1.0, nil, nil, nil, nil, nil, nil, nil, nil, 1_u64,
      operation: "SELECT", pool_wait_ms: 7.5, context: "job:x", adapter: "Postgres")
    full.operation.should eq "SELECT"
    full.pool_wait_ms.should eq 7.5

    old = JSON.parse(plain.to_json).as_h.reject("pool_wait_ms", "context", "adapter", "params_shown").to_json
    Azu::QueryMetric.from_json(old).pool_wait_ms.should eq 0.0
  end

  it "records whether the params are values or placeholders" do
    store = Azu::QueryStore.new
    store.record_query("SELECT 1", ["?", "?"], 1.0, nil, nil, nil, nil, nil, nil, nil, nil, 1_u64).params_shown?.should be_false
    store.record_query("SELECT 1", %w(1 "a"), 1.0, nil, nil, nil, nil, nil, nil, nil, nil, 1_u64, params_shown: true).params_shown?.should be_true
  end
end

describe Azu::PoolSnapshot do
  it "computes usage" do
    pool = Azu::PoolSnapshot.new(open: 4, idle: 2, in_flight: 0, max: 10)
    pool.active.should eq 2
    pool.usage_percent.should eq 20.0
    Azu::PoolSnapshot.new(1, 1, 0, 0).usage_percent.should eq 0.0
  end
end

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

private CANARY = "Zq9Kx7"

private class CodedError < Exception
  getter sqlstate : String

  def initialize(message : String, @sqlstate : String)
    super(message)
  end
end

private def safe(message : String) : String
  Azu::QueryAnalysis.safe_error(Exception.new(message))
end

describe "Azu::QueryAnalysis.safe_error" do
  # Every shape the three reviews found, as a server could quote a data value in it.
  nasty = {
    "unique detail"       => "duplicate key value violates unique constraint \"u\"\nDETAIL: Key (email)=(#{CANARY}@example.com) already exists.",
    "key on one line"     => "duplicate key value violates unique constraint \"u\" DETAIL: Key (email)=(#{CANARY}) already exists.",
    "key multi-line"      => "Key (note)=(line1\nline2-#{CANARY}) already exists.",
    "failing row"         => "new row for relation \"users\" violates check constraint \"c\"\nDETAIL: Failing row contains (1, #{CANARY}, x).",
    "invalid syntax"      => %(invalid input syntax for type integer: "#{CANARY}"),
    "invalid enum"        => %(invalid input value for enum status: "#{CANARY}"),
    "datetime"            => %(date/time field value out of range: "#{CANARY}"),
    "out of range"        => %(value "#{CANARY}" is out of range for type integer),
    "json token"          => "invalid input syntax for type json\nDETAIL: Token \"#{CANARY}\" is invalid.\nCONTEXT: JSON data, line 1: {#{CANARY}",
    "mysql duplicate"     => "Duplicate entry '#{CANARY}@example.com' for key 'users.email'",
    "mysql newline"       => "Duplicate entry 'a\n#{CANARY}' for key 'users.email'",
    "mysql O'Brien"       => "Duplicate entry 'O'Brien-#{CANARY}@example.com' for key 'users.email'",
    "mysql quote+newline" => "Duplicate entry 'it's #{CANARY}\nmore' for key 'users.email'",
    "mysql fake key"      => "Duplicate entry 'x' for key '#{CANARY}'\nmore' for key 'users.email'",
    "mysql incorrect"     => "Incorrect integer value: '#{CANARY}' for column 'age' at row 1",
    "apostrophe"          => "Incorrect integer value: 'it's #{CANARY}' for column 'age' at row 1",
    "quote in value"      => %(invalid input syntax for type integer: "a"#{CANARY}"),
    "name word in value"  => %(invalid input syntax for type integer: "x column "#{CANARY}" y"),
    "relation in value"   => %(invalid input syntax for type integer: "a" relation "#{CANARY}"),
    "timezone"            => %(invalid value for parameter "TimeZone": "#{CANARY}\nmore),
    "timezone quote"      => %(invalid value for parameter "TimeZone": "a"#{CANARY}"),
    "cockroach"           => %(duplicate key value (id)=(#{CANARY}) violates unique constraint "t_pkey"),
    "cockroach columns"   => "duplicate key value (a, b)=(#{CANARY}, x) violates unique constraint",
    "prefix-less hyphen"  => "duplicate key value (my-col)=(#{CANARY})",
    "prefix-less nested"  => "duplicate key value (lower(email))=(#{CANARY})",
    "typographic"         => "Duplicate entry ‘#{CANARY}’ for key ‘users.email’",
    "localized"           => "bad value «#{CANARY}» „#{CANARY}“ ‚#{CANARY}‘ ‹#{CANARY}› 「#{CANARY}」 here",
    "backticks"           => "bad value `#{CANARY}` here",
    "hint"                => "something failed\nHINT: use #{CANARY}",
    "nul"                 => "relation \"users\" does not exist\u0000#{CANARY}",
    "carriage return"     => "relation \"users\" does not exist\r#{CANARY}",
    "invalid utf-8"       => String.new(Bytes[0xff, 0xfe, 0x22]) + "bad #{CANARY} " + String.new(Bytes[0xc3]),
    "invalid utf-8 enum"  => %(invalid input value for enum status: "#{CANARY}) + String.new(Bytes[0xff]) + %("),
  }

  nasty.each do |name, message|
    it "keeps the value out of #{name}" do
      safe(message).should_not contain CANARY
      safe(message).should_not contain "example.com"
    end
  end

  it "shows only the class for a message it does not recognise" do
    safe("something unexpected: #{CANARY}").should eq "Exception"
    safe("").should eq "Exception"
    Azu::QueryAnalysis.safe_error(IO::Error.new("x")).should eq "IO::Error"
  end

  it "builds a canonical text for each recognised shape" do
    {
      %(relation "users" does not exist)                                                           => %(relation "users" does not exist),
      %(column "age" does not exist)                                                               => %(column "age" does not exist),
      %(null value in column "name" of relation "users" violates not-null constraint)              => %(null value in column "name" of relation "users" violates not-null constraint),
      %(null value in column "name" violates not-null constraint)                                  => %(null value in column "name" violates not-null constraint),
      %(duplicate key value violates unique constraint "users_email_key")                          => %(duplicate key value violates unique constraint "users_email_key"),
      %(insert or update on table "posts" violates foreign key constraint "posts_user_fk")         => %(insert or update on table "posts" violates foreign key constraint "posts_user_fk"),
      %(update or delete on table "users" violates foreign key constraint "p_fk" on table "posts") => %(update or delete on table "users" violates foreign key constraint "p_fk" on table "posts"),
      "UNIQUE constraint failed: users.email"                                                      => "UNIQUE constraint failed: users.email",
      "UNIQUE constraint failed: users.a, users.b"                                                 => "UNIQUE constraint failed: users.a, users.b",
      "NOT NULL constraint failed: users.name"                                                     => "NOT NULL constraint failed: users.name",
      "no such table: users"                                                                       => "no such table: users",
      "no such column: age"                                                                        => "no such column: age",
      "Table 'shop.users' doesn't exist"                                                           => "Table 'shop.users' doesn't exist",
      "Unknown column 'age' in 'field list'"                                                       => "Unknown column 'age' in 'field list'",
      "Duplicate entry 'a@b.c' for key 'users.email'"                                              => "Duplicate entry for key 'users.email'",
      %(syntax error at or near "#{CANARY}")                                                       => "syntax error",
      %(near "#{CANARY}": syntax error)                                                            => "syntax error",
      "database is locked"                                                                         => "database is locked",
      "FOREIGN KEY constraint failed"                                                              => "FOREIGN KEY constraint failed",
      %(ERROR: relation "users" does not exist (SQLSTATE 42P01))                                   => %(relation "users" does not exist),
      %(relation "users" does not exist\nDETAIL: whatever #{CANARY})                               => %(relation "users" does not exist),
      %(column "c" of relation "t" does not exist)                                                 => %(column "c" of relation "t" does not exist),
      "CHECK constraint failed: users_age_check"                                                   => "CHECK constraint failed: users_age_check",
    }.each do |message, text|
      safe(message).should eq "Exception: #{text}"
    end
  end

  it "accepts only plain identifiers in a recognised shape" do
    safe(%(relation "a b" does not exist)).should eq "Exception"
    safe(%(relation "#{CANARY}" does not exist, #{CANARY})).should eq "Exception"
    safe(%(relation "a"b" does not exist)).should eq "Exception"
    safe("no such table: a;b").should eq "Exception"
  end

  it "bounds the identifier it echoes" do
    long = "a" * 1_000_000
    safe(%(relation "#{long}" does not exist)).should eq "Exception"
    safe("no such table: #{long}").should eq "Exception"
    safe(%(relation "#{"a" * 128}" does not exist)).bytesize.should be < 200
    safe(%(relation "#{"a" * 129}" does not exist)).should eq "Exception"
    safe("CHECK constraint failed: #{long}").bytesize.should be < 100
  end

  it "adds the SQLSTATE the exception exposes" do
    Azu::QueryAnalysis.safe_error(CodedError.new("no such table: t", "42P01")).should eq "CodedError (SQLSTATE 42P01): no such table: t"
    Azu::QueryAnalysis.safe_error(CodedError.new("whatever #{CANARY}", "23505")).should eq "CodedError (SQLSTATE 23505)"
    Azu::QueryAnalysis.safe_error(CodedError.new("x #{CANARY}", "bad code #{CANARY}")).should eq "CodedError"
  end

  it "stays fast on a megabyte of nasty input" do
    inputs = ["'x" * 500_000, "relation \"a\" " * 100_000, "'a\"b`c‘d“e" * 100_000, "x" * 1_000_000 + "'", "Duplicate entry '" + "'' for key '" * 90_000,
              "\n" * 1_000_000, String.new(Bytes.new(1_000_000, 0xff_u8)), "(" * 1_000_000]
    inputs.each do |message|
      Time.measure { safe(message).should_not contain CANARY }.should be < 2.seconds
    end
  end

  it "keeps a canary out of messages generated from server shapes and nasty values" do
    templates = [
      "Duplicate entry '%V%' for key 'users.email'", "Incorrect integer value: '%V%' for column 'age' at row 1",
      "invalid input syntax for type integer: \"%V%\"", "invalid input value for enum status: \"%V%\"",
      "invalid value for parameter \"TimeZone\": \"%V%\"", "duplicate key value (id)=(%V%) violates unique constraint \"t_pkey\"",
      "duplicate key value (my-col)=(%V%)", "duplicate key value (lower(email))=(%V%)", "Key (email)=(%V%) already exists.",
      "duplicate key value violates unique constraint \"u\"\nDETAIL: Key (email)=(%V%) already exists.",
      "new row violates check constraint \"c\"\nDETAIL: Failing row contains (1, %V%).", "value \"%V%\" is out of range for type integer",
      "date/time field value out of range: \"%V%\"", "invalid input syntax for type json\nDETAIL: Token \"%V%\" is invalid.\nCONTEXT: JSON data, line 1: %V%",
      "syntax error at or near \"%V%\"", "near \"%V%\": syntax error", "relation \"u\" does not exist\nDETAIL: %V%",
      "Data too long for column 'name' at row 1: %V%", "Truncated incorrect DOUBLE value: '%V%'", "%V%",
    ]
    fragments = [CANARY, "it's #{CANARY}", "a\"#{CANARY}", "x\n#{CANARY}", "DETAIL: #{CANARY}", "CONTEXT: #{CANARY}", "HINT: #{CANARY}",
                 "«#{CANARY}»", "„#{CANARY}“", "‚#{CANARY}‘", "「#{CANARY}」", "'#{CANARY}'", "`#{CANARY}`", "a' for key '#{CANARY}", "#{CANARY}\r\nmore",
                 "\u0000#{CANARY}", ")=(#{CANARY}", "Key (a)=(#{CANARY}", "contains (#{CANARY}", "#{CANARY}" + String.new(Bytes[0xff]), "x\" relation \"#{CANARY}"]
    random = Random.new(7)
    templates.each do |template|
      600.times do
        value = Array.new(random.rand(1..3)) { fragments.sample(random) }.join(random.next_bool ? "" : " ")
        message = template.gsub("%V%", value)
        safe(message).should_not contain CANARY
      end
    end
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

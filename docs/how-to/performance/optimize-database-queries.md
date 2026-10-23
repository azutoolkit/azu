# How to Optimize Database Queries

This guide shows you how to improve database performance in an Azu application that uses CQL. To see what your app
actually runs, `require "azu/cql"`: the dev dashboard's Database tab lists every statement tagged with its request,
flags slow queries and detects N+1 patterns (see [Database dashboard](../../reference/database-dashboard.md)).

Every example is self-contained: it defines the schema and models it needs.

## Use Indexes

Add indexes for columns you filter, join and sort on. Indexes declared inside a `table` block are not created, so
create them in a [migration](../database/run-migrations.md) (or with `schema.alter`):

```crystal
require "cql"

class AddQueryIndexes < CQL::Migration(20240201090000_i64)
  def up
    schema.alter :users do
      create_index :index_users_on_email, [:email], unique: true
    end

    schema.alter :posts do
      create_index :index_posts_on_user_id, [:user_id]
      create_index :index_posts_on_user_id_and_created_at, [:user_id, :created_at]
    end

    schema.alter :orders do
      create_index :index_orders_on_status, [:status]
    end
  end

  def down
    schema.alter :users do
      drop_index :index_users_on_email
    end

    schema.alter :posts do
      drop_index :index_posts_on_user_id
      drop_index :index_posts_on_user_id_and_created_at
    end

    schema.alter :orders do
      drop_index :index_orders_on_status
    end
  end
end
```

## Analyze Query Plans

Ask the database how it runs a statement. `EXPLAIN` is a SQL statement like any other, so run it through the connection:

```crystal
require "cql"
require "pg"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_URL"]) do
  table :users do
    primary :id, Int64
    column :email, String
  end
end

plan = AcmeDB.exec_query do |connection|
  connection.query_all("EXPLAIN ANALYZE SELECT * FROM users WHERE email = $1", "test@example.com", as: String)
end

puts plan.join("\n")

# Look for:
# - Seq Scan on a large table (bad)
# - Index Scan (good)
# - Index Only Scan (best)
```

In development, the dashboard's SQL playground accepts one `EXPLAIN` statement and shows the result without leaving the
browser. To see the SQL a CQL query will run, call `to_sql_with_params` on it.

## Avoid N+1 Queries

### The Problem

Reading an association inside a loop runs one query per record:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property user_id : Int64
  property title : String

  belongs_to :user, User, :user_id

  def initialize(@user_id : Int64, @title : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String

  has_many :posts, Post, foreign_key: :user_id

  def initialize(@name : String)
  end
end

# Bad: N+1 queries, one posts query per user
User.all.each do |user|
  puts "#{user.name}: #{user.posts.size}"
end
```

### The Solution

`preload` loads the `has_many` associations of every returned record with one extra query. It works for `has_many`
only; a `belongs_to` target is best loaded by joining or by fetching the parents with one `where(id: ids)`:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property user_id : Int64
  property title : String

  belongs_to :user, User, :user_id

  def initialize(@user_id : Int64, @title : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String

  has_many :posts, Post, foreign_key: :user_id

  def initialize(@name : String)
  end
end

# Good: two queries in total
User.preload(:posts).all.each do |user|
  puts "#{user.name}: #{user.posts.size}"
end

# belongs_to side: one query for the posts, one for their authors
posts = Post.limit(50).all
authors = User.where(id: posts.map(&.user_id).uniq!).all.index_by(&.id!)
posts.each { |post| puts "#{post.title} by #{authors[post.user_id].name}" }

# Or let the database count: one grouped query
counts = AcmeDB.query
  .from(:posts)
  .select(:user_id)
  .count(as: :total)
  .group(:user_id)
  .all(as: {Int64, Int64})
```

## Select Only Needed Columns

`select` with symbols loads only those columns, which matters for wide rows and large text or blob columns:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :posts do
    primary :id, Int64
    column :title, String
    column :body, String
    timestamps
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property title : String
  property body : String
  property created_at : Time?

  def initialize(@title : String, @body : String)
  end
end

# Bad: loads every column, including the body
posts = Post.all

# Good: only what the listing needs
rows = Post.select(:id, :title, :created_at).all
rows.each { |row| puts "#{row.id} #{row.title}" }

# Single columns without building records
titles = Post.pluck(:title, as: {String})
```

## Use Batch Processing

Process large tables in batches instead of loading them whole:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :email, String
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property email : String

  def initialize(@email : String)
  end
end

def process(user : User) : Nil
  puts user.email
end

# Bad: loads all records into memory
User.all.each { |user| process(user) }

# Good: process in batches of 1000
User.find_each(batch_size: 1000) { |user| process(user) }

# Or with explicit batches
User.find_in_batches(batch_size: 1000) do |batch|
  batch.each { |user| process(user) }
end
```

## Count and Check Existence in the Database

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :orders do
    primary :id, Int64
    column :user_id, Int64
    column :status, String
    column :total, Float64
  end
end

class Order
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :orders

  property user_id : Int64
  property status : String
  property total : Float64

  def initialize(@user_id : Int64, @status : String, @total : Float64)
  end
end

user_id = 1_i64

# Bad: loads every order to count them
count = Order.where(user_id: user_id).all.size

# Good: COUNT in the database
count = Order.where(user_id: user_id).count

# Bad: counts every match just to compare with zero
has_orders = Order.where(user_id: user_id).count > 0

# Good: stops at the first match
has_orders = Order.where(user_id: user_id).exists?

# Aggregations run in the database too
revenue = Order.sum(:total)
average = Order.average(:total)
largest = Order.maximum(:total)
```

## Limit Result Sets

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :posts do
    primary :id, Int64
    column :title, String
    timestamps
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property title : String
  property created_at : Time?

  def initialize(@title : String)
  end
end

# Bad: no limit
recent_posts = Post.order(created_at: :desc).all

# Good: always limit
recent_posts = Post.order(created_at: :desc).limit(10).all
```

## Batch Writes

Single statements beat loops of single-row statements. `update_by` updates all matching rows in one `UPDATE`;
`schema.insert` takes an array of rows for one multi-row `INSERT`. Neither runs validations or callbacks:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :active, Bool, default: true
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String
  property active : Bool = true

  def initialize(@name : String, @email : String)
  end
end

# Bad: one UPDATE per record
User.where(active: true).all.each { |user| user.update!(active: false) }

# Good: one UPDATE
User.update_by({:active => true.as(DB::Any)}, {:active => false.as(DB::Any)})

# Bad: one INSERT per record
[{"A", "a@example.com"}, {"B", "b@example.com"}].each do |name, email|
  User.create!(name: name, email: email)
end

# Good: one multi-row INSERT
rows = [
  {:name => "A".as(DB::Any), :email => "a@example.com".as(DB::Any)},
  {:name => "B".as(DB::Any), :email => "b@example.com".as(DB::Any)},
] of Hash(Symbol, DB::Any)
AcmeDB.insert.into(:users).values(rows).commit
```

## Parameters and Prepared Statements

CQL always binds values as parameters, never interpolating them into the SQL text, so repeated queries share a
statement and the driver can cache and reuse the prepared statement (crystal-db prepares statements by default).

## Connection Pooling

The pool belongs to the crystal-db connection: set its size with URI parameters (`initial_pool_size`, `max_pool_size`,
`max_idle_pool_size`, `checkout_timeout` in seconds). With `require "azu/cql"`, `Azu::CQL.schema` fills them from
`CQL.config.pool` and leaves parameters already in the URL alone:

```crystal
require "cql"
require "pg"

pool_size = ENV.fetch("DB_POOL_SIZE", "20").to_i
base = ENV["DATABASE_URL"]

AcmeDB = CQL::Schema.define(
  :acme,
  adapter: CQL::Adapter::Postgres,
  uri: "#{base}?initial_pool_size=2&max_pool_size=#{pool_size}&max_idle_pool_size=#{pool_size}&checkout_timeout=5"
) do
  table :users do
    primary :id, Int64
    column :name, String
  end
end
```

A common starting point is `pool_size = (cores * 2) + 1` per process; remember that the database's connection limit is
shared by every process you run.

## Query Caching

Cache the result of expensive queries with Azu's cache, which stores strings (serialize the result) and takes a
`ttl`:

```crystal
require "azu"
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :active, Bool, default: true
  end

  table :orders do
    primary :id, Int64
    column :total, Float64
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property active : Bool = true

  def initialize
  end
end

class Order
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :orders

  property total : Float64

  def initialize(@total : Float64)
  end
end

def expensive_stats : String
  Azu.cache.fetch("stats:#{Time.utc.to_s("%Y-%m-%d")}", ttl: 1.hour) do
    {
      total_users:  User.count,
      active_users: User.where(active: true).count,
      total_orders: Order.count,
      revenue:      Order.sum(:total),
    }.to_json
  end
end

expensive_stats
```

## Read Replicas

CQL has no replica routing. If you run a replica, define a second schema for it and bind read-only models to that schema;
writes keep going through the primary models:

```crystal
require "cql"
require "pg"

PrimaryDB = CQL::Schema.define(:primary, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_URL"]) do
  table :reports do
    primary :id, Int64
    column :title, String
  end
end

ReplicaDB = CQL::Schema.define(:replica, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_REPLICA_URL"]) do
  table :reports do
    primary :id, Int64
    column :title, String
  end
end

class Report
  include CQL::ActiveRecord::Model(Int64)
  db_context PrimaryDB, :reports

  property title : String

  def initialize(@title : String)
  end
end

class ReplicaReport
  include CQL::ActiveRecord::Model(Int64)
  db_context ReplicaDB, :reports

  property title : String

  def initialize(@title : String)
  end
end

Report.create!(title: "Q3")                    # primary
ReplicaReport.order(:id).limit(20).all         # replica
```

Replicas lag behind the primary, so read your own writes from the primary.

## Optimize Specific Patterns

### Pagination

Large `OFFSET` values scan and discard every skipped row. Use keyset pagination: `after_cursor` filters on the primary
key, `paginate_by` on another column:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String

  def initialize(@name : String)
  end
end

# Bad: OFFSET with large values scans 10,020 rows
User.order(:id).offset(10_000).limit(20).all

# Good: keyset pagination
last_id = 10_020_i64
User.after_cursor(last_id, 20)
User.paginate_by(:name, "Smith", 20)
```

### Search

A `LIKE` with a leading wildcard cannot use a normal index. Prefer a prefix match, or the database's full-text search:

```crystal
require "cql"
require "pg"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_URL"]) do
  table :users do
    primary :id, Int64
    column :name, String
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String

  def initialize(@name : String)
  end
end

search_term = "smith"

# Bad: a leading wildcard cannot use an index
User.where("name LIKE ?", "%#{search_term}%").all

# Better: a prefix match can use a btree index (PostgreSQL needs text_pattern_ops outside the C locale)
User.where("name LIKE ?", "#{search_term}%").all

# PostgreSQL full-text search
User.where("to_tsvector('english', name) @@ plainto_tsquery('english', ?)", search_term).all
```

### Date Ranges

Wrapping an indexed column in a function defeats the index; compare against a range instead:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :orders do
    primary :id, Int64
    column :total, Float64
    timestamps
  end
end

class Order
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :orders

  property total : Float64
  property created_at : Time?

  def initialize(@total : Float64)
  end
end

date = Time.utc(2024, 3, 1)

# Bad: a function on the indexed column
Order.where("DATE(created_at) = ?", date.to_s("%Y-%m-%d")).all

# Good: a range
Order.where("created_at >= ? AND created_at < ?", date.at_beginning_of_day, date.at_beginning_of_day + 1.day).all
```

## Monitor Query Performance

Subscribe to CQL's telemetry to be told about slow statements. The callback receives a `CQL::Telemetry::QueryEvent`
with the SQL, duration, operation and rows affected:

```crystal
require "cql"

CQL::Telemetry.alert_on_slow(100.milliseconds) do |event|
  Log.warn { "Slow query (#{event.duration.total_milliseconds.round(1)}ms): #{event.sql}" }
end

statements = Atomic(Int32).new(0)
CQL::Telemetry.subscribe("app.statement_counter") { |_event| statements.add(1) }
```

With `require "azu/cql"` the dashboard subscribes the same way and also logs queries slower than
`database.slow_query_ms` (see [Database dashboard](../../reference/database-dashboard.md)).

## See Also

- [Optimize Endpoints](optimize-endpoints.md)
- [Query Data](../database/query-data.md)

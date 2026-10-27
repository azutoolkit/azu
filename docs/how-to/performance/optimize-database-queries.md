---
description: Improve database performance in an Azu application that uses CQL.
---

# Optimize database queries

To see what your app actually runs, `require "azu/cql"`: the dev dashboard's Database tab lists every statement tagged
with its request, flags slow queries and detects N+1 patterns (see
[Database dashboard](../../reference/database-dashboard.md)).

Every example is self-contained: it defines the schema and models it needs.

## Use indexes

Add indexes for columns you filter, join and sort on. Indexes declared inside a `table` block (`index [...]`,
`index: true`) are created with the table by `build` and `create!` (see
[Define a schema](../database/define-schema.md#indexes)). To add them to tables that already exist, use a
[migration](../database/run-migrations.md) (or `schema.alter`):

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

## Analyze query plans

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
```

In development, the dashboard's SQL playground accepts one `EXPLAIN` statement and shows the result without leaving the
browser. To see the SQL a CQL query will run, call `to_sql_with_params` on it.

## Avoid N+1 queries

### The problem

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

### The solution

`preload` loads the named association of every returned record with one extra query (one per chunk of ids when there
are more ids than the database accepts as parameters). It works for `has_many`, `has_one` and `belongs_to`:

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
Post.limit(50).preload(:user).all.each do |post|
  puts "#{post.title} by #{post.user.try(&.name)}"
end

# Or let the database count: one grouped query
counts = AcmeDB.query
  .from(:posts)
  .select(:user_id)
  .count(as: :total)
  .group(:user_id)
  .all(as: {Int64, Int64})
```

### Catch repeated queries

The dashboard groups queries by shape. To see the exact same query running twice in a request, turn on CQL's cache
and let the CQL middleware count repeats:

<!-- skip -->
```crystal
Azu::CQL.configure { |config| config.cache.on = true }

handlers = [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::CQL::Middleware.new(AcmeDB, query_cache: true),
] of HTTP::Handler

# anywhere in the request, e.g. at the end of an endpoint's `call`
if stats = Azu::CQL.request_cache_stats
  Log.warn { "#{stats.repeated} repeated queries" } if stats.repeated > 0
end
```

It stores no rows and speeds nothing up, and requests served at the same time share CQL's counters for now; see
[Repeated queries per request](../../reference/api/cql-bridge.md#repeated-queries-per-request).

## Select only needed columns

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

## Use batch processing

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

## Count and check existence in the database

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

## Limit result sets

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

## Batch writes

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

## Parameters and prepared statements

CQL always binds values as parameters, never interpolating them into the SQL text, so repeated queries share a
statement and the driver can cache and reuse the prepared statement (crystal-db prepares statements by default).

## Connection pooling

A schema made with `CQL::Schema.define` uses crystal-db's pool: set its size with URI parameters (`initial_pool_size`,
`max_pool_size`, `max_idle_pool_size`, `checkout_timeout` in seconds). With `require "azu/cql"`, `Azu::CQL.schema`
on a `postgres://` URL uses CQL's own engine pool instead (sized with `pool_size`, `pool_min_size` and
`checkout_timeout`; crystal-db's names are translated), unless `driver: :db` or `AZU_CQL_DRIVER=db` keeps
crystal-db's. When its URL comes from `CQL.config`, `Azu::CQL.schema` fills the pool settings from `CQL.config.pool`,
and parameters already in the URL win (see [Configure production](../deployment/configure-production.md#database-connections)):

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

{% hint style="warning" %}
Each process has its own pool, and the database's connection limit is shared by every process you run.
{% endhint %}

## Query caching

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

## Read replicas

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

{% hint style="warning" %}
Replicas lag behind the primary, so read your own writes from the primary.
{% endhint %}

## Optimize specific patterns

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

## Monitor query performance

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

## See also

- [Optimize Endpoints](optimize-endpoints.md)
- [Query Data](../database/query-data.md)

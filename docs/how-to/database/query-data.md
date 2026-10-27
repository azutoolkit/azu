---
description: Query data with CQL models.
---

# Query data

Model queries return a `QueryBuilder`. Every method that adds a condition returns a new builder, so queries chain, and
nothing touches the database until you ask for records (`all`, `first`, `count`, ...).

Before you start: a project made by `azu new` and models for your tables (see [Create models](create-models.md)). The
examples on this page query these two models, laid out in the files `azu new` and `azu generate model` write:

<!-- prelude -->
```crystal
# src/initializers/cql_config.cr
require "sqlite3"
require "azu/cql"

Azu::CQL.configure do |c|
  c.db = ENV["DATABASE_URL"]? || "sqlite3://./db/acme.db"
end

# src/db/schema.cr
AcmeDB = Azu::CQL.schema :acme do
  table :users do
    primary :id, Int64
    text :name
    text :email
    column :age, Int32, null: true
    text :role, default: "user"
    boolean :active, default: true
    timestamp :deleted_at, null: true
    timestamps
  end

  table :posts do
    primary :id, Int64
    bigint :user_id
    text :title
    boolean :published, default: false
    integer :views, default: 0
    timestamps

    foreign_key :user_id, references: :users
  end
end

# src/models/user.cr
class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String
  property age : Int32?
  property role : String = "user"
  property active : Bool = true
  property deleted_at : Time?
  property created_at : Time?
  property updated_at : Time?

  has_many :posts, Post, foreign_key: :user_id

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

# src/models/post.cr
class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property user_id : Int64
  property title : String
  property published : Bool = false
  property views : Int32 = 0
  property created_at : Time?
  property updated_at : Time?

  belongs_to :user, User, :user_id

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_author, ->(user_id : Int64) { where(user_id: user_id) }
  scope :popular, -> { where("views > ?", 100) }

  def initialize(@user_id : Int64, @title : String)
  end
end
```

## Finding records

`find` and `find?` return the record or `nil`; `find!` and `find_by!` raise `DB::NoResultsError` when nothing matches.
`first` and `last` order by the primary key unless you order the query yourself; `first!` and `last!` raise:

```crystal
# By primary key
user = User.find(1_i64)    # User?
user = User.find?(1_i64)   # User?, same as find
user = User.find!(1_i64)   # User, raises DB::NoResultsError

# By attributes
user = User.find_by(email: "alice@example.com")   # User?
user = User.find_by!(email: "alice@example.com")  # User, raises DB::NoResultsError
user = User.find_by(role: "admin", active: true)  # several attributes

# Everything, first and last
users = User.all   # Array(User)
first_user = User.first
last_user = User.last
oldest = User.order(created_at: :asc).first
```

## Filtering with where

Keyword arguments are combined with `AND`, and an array value becomes an `IN` list. A string with `?` placeholders (or
`:name` placeholders with keyword arguments) is bound as parameters, never interpolated. The block form gives you the
model's typed columns: conditions combine with `&`, `|` and `.not`, and a column offers `==`, `!=`, `>`, `>=`, `<`, `<=`,
`like`, `in`, `between`, `null` and `not_null`. Repeated `where` calls are combined with `AND`:

```crystal
active_users = User.where(active: true).all
staff = User.where(role: ["admin", "moderator"]).all
admin_users = User.where(active: true, role: "admin").all

# SQL fragments with bound parameters
adults = User.where("age > ?", 18).all
smiths = User.where("name LIKE ?", "%Smith%").all
staff = User.where("role IN (?)", ["admin", "moderator"]).all
older = User.where("age > :min", min: 18).all
unverified = User.where("deleted_at IS NULL").all

# The column DSL
adults = User.where { age > 18 }.all
admin_adults = User.where { (age > 18) & (role == "admin") }.all
staff = User.where { (role == "admin") | (role == "moderator") }.all
not_admins = User.where { (role == "admin").not }.all
not_deleted = User.where { deleted_at.null }.all
a_names = User.where { name.like("A%") }.all

# Shortcuts on the builder
smith = User.where_like(:name, "%Smith%").all
adults = User.query.where_gt(:age, 18).all

# Chaining
users = User
  .where(active: true)
  .where("age >= ?", 18)
  .where("created_at > ?", Time.utc - 30.days)
  .all
```

`where(deleted_at: nil)` produces `WHERE users.deleted_at IS NULL`, the same check as the block form
`deleted_at.null` and the SQL fragment above.

## Ordering, limits and pagination

`order` takes symbols (ascending) or keyword arguments with a direction. The argument is a column name, not a SQL
expression. `User.page(2, 20)` returns the second page of 20 records and `User.per_page(20)` the first;
`after_cursor` and `paginate_by` do keyset pagination, which stays fast on large tables:

```crystal
users = User.order(name: :asc).all
users = User.order(created_at: :desc).all
users = User.order(role: :asc, name: :desc).all
users = User.order(:role, :name).all
users = User.order(:name).reorder(:id).all   # replace the ordering
users = User.order(:id).reverse_order.all

first_ten = User.limit(10).all
page_two = User.order(:id).limit(10).offset(10).all

page = User.page(2, 20)                      # Array(User)
next_page = User.after_cursor(100_i64, 20)   # ids greater than 100, ordered by id
by_age = User.paginate_by(:age, 30, 20)      # age greater than 30
```

## Selecting columns

`select` with symbols returns lightweight rows holding only those columns. `pluck` returns column values directly; name
the Crystal types with `as:` when you pluck several columns:

```crystal
rows = User.select(:id, :name).all
rows.each { |row| puts "#{row.id} #{row.name}" }

names = User.pluck(:name)                            # Array(DB::Any)
pairs = User.pluck(:id, :name, as: {Int64, String})  # Array({Int64, String})
first_name = User.pick(:name, as: String)
admin_ids = User.where(role: "admin").ids            # Array(Int64)
roles = User.distinct(:role, as: String)
```

## Aggregations

`count`, `sum`, `average`, `minimum` and `maximum` run in the database. The model builder has no grouped aggregates:
build the query on the schema and read tuples. With one admin and four other users:

```crystal
total = User.count                                   # Int64
admin_count = User.where(role: "admin").count
with_email = User.count(:email)
oldest = User.maximum(:age)
average_age = User.average(:age)

counts = AcmeDB.query.from(:users).select(:role).count(as: :total).group(:role).all(as: {String, Int64})
counts                                               # => [{"admin", 1}, {"user", 4}]

busy_roles = AcmeDB.query
  .from(:users)
  .select(:role)
  .count(as: :total)
  .group(:role)
  .having { count(:id) > 1 }
  .all(as: {String, Int64})
busy_roles                                           # => [{"user", 4}]
```

## Joins, associations and scopes

`joins` and `left_joins` take an association name declared with `belongs_to` or `has_many`; the join condition comes
from the foreign key and the query still returns the model it started from. An association is a collection you can read
or narrow: `where` on it returns a `CQL::Query`, so pass the model to `all`.

A `scope` is a named, chainable query defined on the model (the four on `Post` above). Scopes compose with each other
and with `where`, `order` and `limit`:

```crystal
published_with_authors = Post.query.joins(:user).where(published: true).all
users_with_or_without_posts = User.query.left_joins(:posts).distinct.all

user = User.find!(1_i64)
posts = user.posts.to_a
published = user.posts.where(published: true).all(Post)
count = user.posts.count
author = Post.find!(1_i64).user   # User?

Post.published.recent.all
Post.by_author(1_i64).published.limit(5).all
Post.published.popular.count
```

## Eager loading

Reading an association per record runs one query per record (the N+1 problem). `preload` loads the named association
of all records with one extra query. It works for `has_many`, `has_one` and `belongs_to`:

```crystal
# N+1: one query for users, then one per user
User.all.each { |user| puts user.posts.size }

# Two queries in total
User.preload(:posts).all.each { |user| puts user.posts.size }

# belongs_to: two queries in total as well
Post.preload(:user).all.each { |post| puts post.user.try(&.name) }
```

In development the dev dashboard's Database tab reports a `SELECT` that one request repeats, as the first loop does
(see [N+1 detection](../../reference/database-dashboard.md#n1-detection)).

## Count repeated queries per request

Curious how often one request runs the very same statement? Switch on CQL's request cache and pass `query_cache: true`
to `Azu::CQL::Middleware`. Mount it after `RequestId`, so the counts are filed under the request's `X-Request-ID`:

```crystal
Azu::CQL.configure do |c|
  c.cache.on = true            # CQL's cache is off by default, and the request cache is part of it
  c.cache.request_cache = true # already the default once the cache is on
end

handlers = [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::CQL::Middleware.new(AcmeDB, query_cache: true),
] of HTTP::Handler
```

Anywhere inside the request, `Azu::CQL.request_cache_stats` tells you what it has run so far:

```crystal
if stats = Azu::CQL.request_cache_stats
  Log.info { "#{stats.request_id}: #{stats.queries} queries, #{stats.repeated} repeated" }
end
```

`repeated` counts the statements that already ran in this request with the same SQL and the same parameters, such as a
`User.find(id)` that three helpers each call. It is a diagnostic, not a speed-up: CQL stores no rows, and every statement
still reaches the database. The stats are `nil` outside such a request and while CQL's cache is off.

## Raw SQL

`schema.exec_query` yields a `DB::Connection` that takes `?` parameters (`$1` on PostgreSQL). `schema.exec` runs one SQL
string and takes no parameters, so bind values through the connection:

```crystal
names = AcmeDB.exec_query do |connection|
  connection.query_all("SELECT name FROM users WHERE age > ?", 21, as: String)
end

total = AcmeDB.exec_query do |connection|
  connection.scalar("SELECT COUNT(*) FROM users WHERE active = ?", true).as(Int64)
end

AcmeDB.exec("UPDATE users SET role = 'user' WHERE role IS NULL")

AcmeDB.exec_query do |connection|
  connection.exec("UPDATE users SET age = ? WHERE id = ?", 31, 1)
end

sql = <<-SQL
  SELECT u.name, COUNT(p.id) AS post_count
  FROM users u
  LEFT JOIN posts p ON p.user_id = u.id
  WHERE u.active = ?
  GROUP BY u.id
  HAVING COUNT(p.id) > ?
  ORDER BY post_count DESC
  LIMIT 10
SQL

rows = AcmeDB.exec_query do |connection|
  connection.query_all(sql, true, 5, as: {String, Int64})
end
```

## Existence, batches and bulk changes

`find_each` and `find_in_batches` walk a large table without loading it at once.

{% hint style="warning" %}
`update_by`, `update_all` and `delete_by!` run one statement; `update_all` without a condition changes every row, and
none of them run callbacks.
{% endhint %}

`delete_all` on a query loads the records and calls `delete!` on each, so their callbacks run:

```crystal
exists = User.exists?(email: "alice@example.com")
any_admin = User.where(role: "admin").any?
nobody_banned = User.where(role: "banned").empty?
several = User.where(role: "admin").many?
nothing = User.none.all   # always an empty array

User.find_each(batch_size: 1000) do |user|
  puts user.email
end

User.find_in_batches(batch_size: 500) do |batch|
  puts batch.size
end

User.update_by({:role => "user".as(DB::Any)}, {:active => false.as(DB::Any)})
User.update_all({:active => true.as(DB::Any)})
User.delete_by!(role: "banned")
User.where(active: false).delete_all
```

## See also

- [Create models](create-models.md)
- [Handle transactions](handle-transactions.md)
- [Query methods](../../reference/database/query-methods.md)

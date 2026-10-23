# How to Query Data

This guide shows you how to query data with CQL models. Every example is self-contained: it defines the schema and the
models it needs. In an application they live in their own files (see [Create Models](create-models.md)).

Model queries return a `QueryBuilder`. Every method that adds a condition returns a new builder, so queries chain, and
nothing touches the database until you ask for records (`all`, `first`, `count`, ...).

## Finding Records

`find` and `find?` return the record or `nil`; `find!` and `find_by!` raise `DB::NoResultsError` when nothing matches.
`first` and `last` order by the primary key unless you order the query yourself; `first!` and `last!` raise:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :age, Int32, null: true
    column :role, String, default: "user"
    column :active, Bool, default: true
    column :deleted_at, Time, null: true
    timestamps
  end
end

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

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

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

## Filtering with Where

Keyword arguments are combined with `AND`, and an array value becomes an `IN` list. A string with `?` placeholders (or
`:name` placeholders with keyword arguments) is bound as parameters, never interpolated. The block form gives you the
model's typed columns: conditions combine with `&`, `|` and `.not`, and a column offers `==`, `!=`, `>`, `>=`, `<`, `<=`,
`like`, `in`, `between`, `null` and `not_null`. Repeated `where` calls are combined with `AND`:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :age, Int32, null: true
    column :role, String, default: "user"
    column :active, Bool, default: true
    column :deleted_at, Time, null: true
    timestamps
  end
end

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

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

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

`where(deleted_at: nil)` does not produce `IS NULL` (it compares with `= NULL` and matches nothing); use the block
form or a SQL fragment for null checks, as above.

## Ordering, Limits and Pagination

`order` takes symbols (ascending) or keyword arguments with a direction. The argument is a column name, not a SQL
expression. `User.page(2, 20)` returns the second page of 20 records and `User.per_page(20)` the first;
`after_cursor` and `paginate_by` do keyset pagination, which stays fast on large tables:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :age, Int32, null: true
    column :role, String, default: "user"
    column :active, Bool, default: true
    column :deleted_at, Time, null: true
    timestamps
  end
end

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

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

users = User.order(name: :asc).all
users = User.order(created_at: :desc).all
users = User.order(role: :asc, name: :desc).all
users = User.order(:role, :name).all
users = User.order(:name).reorder(:id).all   # replace the ordering
users = User.order(:id).reverse_order.all

first_ten = User.limit(10).all
page_two = User.order(:id).limit(10).offset(10).all

page = User.page(2, 20)                 # Array(User)
next_page = User.after_cursor(100_i64, 20)   # ids greater than 100, ordered by id
by_age = User.paginate_by(:age, 30, 20)      # age greater than 30
```

## Selecting Columns

`select` with symbols returns lightweight rows holding only those columns. `pluck` returns column values directly; name
the Crystal types with `as:` when you pluck several columns:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :age, Int32, null: true
    column :role, String, default: "user"
    column :active, Bool, default: true
    column :deleted_at, Time, null: true
    timestamps
  end
end

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

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

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
build the query on the schema and read tuples:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :age, Int32, null: true
    column :role, String, default: "user"
    column :active, Bool, default: true
    column :deleted_at, Time, null: true
    timestamps
  end
end

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

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

total = User.count                                   # Int64
admin_count = User.where(role: "admin").count
with_email = User.count(:email)
oldest = User.maximum(:age)
average_age = User.average(:age)

counts = AcmeDB.query
  .from(:users)
  .select(:role)
  .count(as: :total)
  .group(:role)
  .all(as: {String, Int64})   # [{"admin", 1}, {"user", 4}]

busy_roles = AcmeDB.query
  .from(:users)
  .select(:role)
  .count(as: :total)
  .group(:role)
  .having { count(:id) > 1 }
  .all(as: {String, Int64})
```

## Joins, Associations and Scopes

`joins` and `left_joins` take an association name declared with `belongs_to` or `has_many`; the join condition comes
from the foreign key and the query still returns the model it started from. An association is a collection you can read
or narrow: `where` on it returns a `CQL::Query`, so pass the model to `all`.

A `scope` is a named, chainable query defined on the model. Scopes compose with each other and with `where`, `order`
and `limit`:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
    column :published, Bool, default: false
    column :views, Int32, default: 0
    timestamps

    foreign_key :user_id, references: :users
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property user_id : Int64
  property title : String
  property published : Bool = false
  property views : Int32 = 0
  property created_at : Time?

  belongs_to :user, User, :user_id

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_author, ->(user_id : Int64) { where(user_id: user_id) }
  scope :popular, -> { where("views > ?", 100) }

  def initialize(@user_id : Int64, @title : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String

  has_many :posts, Post, foreign_key: :user_id

  def initialize(@name : String, @email : String)
  end
end

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

## Eager Loading

Reading an association per record runs one query per record (the N+1 problem). `preload` loads the `has_many`
associations of all records with one extra query. It is implemented for `has_many` only; for a `belongs_to` target use a
join or load the parents with one `where(id: ids)` query:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
    column :published, Bool, default: false
    column :views, Int32, default: 0
    timestamps

    foreign_key :user_id, references: :users
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property user_id : Int64
  property title : String
  property published : Bool = false
  property views : Int32 = 0
  property created_at : Time?

  belongs_to :user, User, :user_id

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_author, ->(user_id : Int64) { where(user_id: user_id) }
  scope :popular, -> { where("views > ?", 100) }

  def initialize(@user_id : Int64, @title : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String

  has_many :posts, Post, foreign_key: :user_id

  def initialize(@name : String, @email : String)
  end
end

# N+1: one query for users, then one per user
User.all.each { |user| puts user.posts.size }

# Two queries in total
User.preload(:posts).all.each { |user| puts user.posts.size }
```

## Raw SQL

`schema.exec_query` yields a `DB::Connection` that takes `?` parameters (`$1` on PostgreSQL). `schema.exec` runs one SQL
string and takes no parameters, so bind values through the connection:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :age, Int32, null: true
    column :role, String, default: "user"
    column :active, Bool, default: true
    column :deleted_at, Time, null: true
    timestamps
  end
end

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

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

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

## Existence, Batches and Bulk Changes

`find_each` and `find_in_batches` walk a large table without loading it at once. `update_by`, `update_all` and
`delete_by!` run one statement; `update_all` without a condition changes every row, and none of them run callbacks.
`delete_all` on a query loads the records and calls `delete!` on each, so their callbacks run:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :age, Int32, null: true
    column :role, String, default: "user"
    column :active, Bool, default: true
    column :deleted_at, Time, null: true
    timestamps
  end
end

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

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

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

## See Also

- [Create Models](create-models.md)
- [Handle Transactions](handle-transactions.md)
- [Query Methods Reference](../../reference/database/query-methods.md)

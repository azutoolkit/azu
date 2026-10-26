---
description: "Every CQL model query method: retrieval, filtering, ordering, limits, selection, aggregates, joins, batches, bulk writes, locking and raw SQL."
---

# Query methods

These are the query methods of a CQL model (`CQL::ActiveRecord::Model`, from the CQL shard: `require "cql"`). A model
class (or a `QueryBuilder`) answers all of them; methods that add conditions return a new `QueryBuilder`, so they
chain. Nothing runs until a method that returns records or a value is called. Each group of examples below is a
complete program. Schemas, models and transactions are on [CQL API](cql-api.md).


## Retrieval methods

| Method | Returns | Notes |
| --- | --- | --- |
| `all` | `Array(T)` | every matching record |
| `first`, `last` | `T?` | ordered by primary key unless the query is ordered |
| `first!`, `last!` | `T` | raise when there is no record |
| `find(id)`, `find?(id)` | `T?` | by primary key |
| `find!(id)` | `T` | raises `DB::NoResultsError` |
| `find_by(**attrs)` | `T?` | first record matching all attributes |
| `find_by!(**attrs)` | `T` | raises `DB::NoResultsError` |
| `each { |record| ... }` | | iterate the matches |
| `to_a` | `Array(T)` | same as `all` on a builder |

There is no `take` or `find_by?`; use `limit(n).all` and `find_by`.


## Filtering

### where

| Form | Example |
| --- | --- |
| keyword arguments | `where(active: true, role: "admin")`, `AND`ed; an array gives `IN` |
| `Hash` | `where({:active => true})` |
| SQL with `?` | `where("age > ?", 18)` |
| SQL with names | `where("age > :min", min: 18)` |
| column DSL block | `where { (age > 18) & (role == "admin") }` |

The DSL block yields the model's typed columns. Operators: `==`, `!=`, `>`, `>=`, `<`, `<=`, `like`, `not_like`, `in`,
`not_in`, `between`, `null`, `not_null`; combine with `&`, `|`, `.not`. Values are always bound as parameters.

### Examples

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
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
  db_context MyDB, :posts

  property user_id : Int64
  property title : String
  property published : Bool = false
  property views : Int32 = 0
  property created_at : Time?

  belongs_to :user, User, :user_id

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id : Int64) { where(user_id: user_id) }

  def initialize(@user_id : Int64, @title : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property name : String
  property email : String
  property age : Int32?
  property role : String = "user"
  property active : Bool = true
  property deleted_at : Time?
  property created_at : Time?

  has_many :posts, Post, foreign_key: :user_id

  scope :active, -> { where(active: true) }
  scope :with_role, ->(role : String) { where(role: role) }

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

users = User.all
user = User.first
newest = User.order(created_at: :desc).first
user = User.find(1_i64)
user = User.find!(1_i64)
user = User.find_by(email: "alice@example.com")
user = User.find_by!(email: "alice@example.com", active: true)

User.where(active: true, role: "admin")
User.where(role: ["admin", "moderator"])         # IN (?, ?)
User.where("age > ?", 18)
User.where("created_at > ?", Time.utc - 7.days)
User.where("name LIKE ?", "%smith%")
User.where("role IN (?)", ["admin", "moderator"])
User.where("deleted_at IS NULL")
User.where { (age > 18) & (role == "admin") }
User.where { (role == "banned").not }
User.where { deleted_at.null }
User.where_like(:name, "%smith%")
User.query.where_gt(:age, 18)
User.query.where_lt(:age, 65)
```

{% hint style="warning" %}
`where(deleted_at: nil)` emits `IS NULL` and matches the rows whose column is NULL, like `where { deleted_at.null }`.
Reject a `nil` that comes from untrusted input before passing it.
{% endhint %}

### Excluding and OR

There is no `where.not(...)` and no `or` method on a builder. Express them with the DSL block:
`User.where { (role == "admin").not }`, `User.where { (role == "admin") | (role == "moderator") }`, or a SQL fragment.
`merge(other_builder)` combines two builders with `AND`.

## Ordering

| Method | Description |
| --- | --- |
| `order(name: :asc)`, `order(role: :asc, name: :desc)` | keyword form with direction |
| `order(:role, :name)` | ascending by each symbol |
| `reorder(...)` | replaces the existing ordering |
| `reverse_order` | flips the directions |

The argument is a column name; `order("LOWER(name) ASC")` is rejected with `Column ... not found`.


## Limiting

`limit(n)` and `offset(n)` take an `Int32`. Model-level helpers paginate in one call:

| Method | Description |
| --- | --- |
| `User.page(page_number, per_page = 10)` | `Array(User)` for a 1-based page |
| `User.per_page(n)` | the first `n` records |
| `User.after_cursor(id, limit = 10)` / `before_cursor(id, limit = 10)` | keyset pagination on the primary key |
| `User.paginate_by(:column, after_value, limit = 10)` | keyset pagination on another column |


## Selection

| Method | Returns |
| --- | --- |
| `select(:id, :name)` | a builder whose `all`/`first` return rows with only those columns |
| `distinct` | the builder with `SELECT DISTINCT` |
| `distinct(:role, as: String)` | the distinct values of a column |
| `pluck(:name)` | `Array(DB::Any)` (on a filtered builder `as:` is required) |
| `pluck(:id, :name, as: {Int64, String})` | `Array({Int64, String})` |
| `pick(:name, as: String)` | the first value |
| `ids` | the primary keys (`Array(Int64)` by default) |

### Examples

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
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
  db_context MyDB, :posts

  property user_id : Int64
  property title : String
  property published : Bool = false
  property views : Int32 = 0
  property created_at : Time?

  belongs_to :user, User, :user_id

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id : Int64) { where(user_id: user_id) }

  def initialize(@user_id : Int64, @title : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property name : String
  property email : String
  property age : Int32?
  property role : String = "user"
  property active : Bool = true
  property deleted_at : Time?
  property created_at : Time?

  has_many :posts, Post, foreign_key: :user_id

  scope :active, -> { where(active: true) }
  scope :with_role, ->(role : String) { where(role: role) }

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

User.order(name: :asc)
User.order(role: :asc, name: :desc)
User.order(:name).reorder(created_at: :desc)
User.order(name: :asc).reverse_order

User.limit(10)
User.order(:id).limit(10).offset(20)
User.page(3, 10)
User.after_cursor(120_i64, 10)

rows = User.select(:id, :name).all
rows.each { |row| puts row.name }

emails = User.where(active: true).pluck(:email, as: String)
pairs = User.pluck(:id, :name, as: {Int64, String})
first_name = User.order(:name).pick(:name, as: String)
ids = User.where(role: "admin").ids
roles = User.distinct(:role, as: String)
```

`select("raw SQL")` is not supported on a model; for expressions use the schema's query builder or raw SQL (below).

## Aggregation

| Method | Returns |
| --- | --- |
| `count`, `count(:column)` | `Int64` |
| `sum(:column)` | the sum (an integer for integer columns) |
| `average(:column)` (`avg`) | `Float64` |
| `minimum(:column)` / `maximum(:column)` (`min` / `max`) | the column's value |
| `size` | same as `count` |


## Grouping

Grouped aggregates are built on the schema's query builder, which returns tuples (see the examples after Existence).


## Joining

`joins` and `left_joins` take association names (`belongs_to`/`has_many`) and derive the `ON` clause from the foreign
key. The block form of `join` takes an explicit condition. They are methods of the builder, so start with `query`.


`preload(:posts)` loads a `has_many`, `has_one` or `belongs_to` association for all returned records in one extra
query.


There is no `includes` and no string-condition `join`/`left_join`.

## Existence

| Method | Returns |
| --- | --- |
| `exists?`, `exists?(**attrs)` | `Bool` |
| `any?` | `Bool`, same as `exists?` |
| `empty?` | `Bool` |
| `many?` | `Bool`, more than one match |
| `none` | a builder that always matches nothing |

There is no `none?`; use `empty?`.

### Examples

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
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
  db_context MyDB, :posts

  property user_id : Int64
  property title : String
  property published : Bool = false
  property views : Int32 = 0
  property created_at : Time?

  belongs_to :user, User, :user_id

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id : Int64) { where(user_id: user_id) }

  def initialize(@user_id : Int64, @title : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property name : String
  property email : String
  property age : Int32?
  property role : String = "user"
  property active : Bool = true
  property deleted_at : Time?
  property created_at : Time?

  has_many :posts, Post, foreign_key: :user_id

  scope :active, -> { where(active: true) }
  scope :with_role, ->(role : String) { where(role: role) }

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

User.count
User.where(active: true).count
User.count(:email)
Post.sum(:views)
Post.where(published: true).average(:views)
Post.minimum(:views)
Post.maximum(:views)

by_role = MyDB.query
  .from(:users)
  .select(:role)
  .count(as: :total)
  .group(:role)
  .all(as: {String, Int64})

busy_roles = MyDB.query
  .from(:users)
  .select(:role)
  .count(as: :total)
  .group(:role)
  .having { count(:id) > 5 }
  .all(as: {String, Int64})

views_per_user = MyDB.query
  .from(:posts)
  .select(:user_id)
  .sum(:views, as: :total)
  .group(:user_id)
  .all(as: {Int64, Int64})

Post.query.joins(:user)
User.query.left_joins(:posts).distinct
Post.query.joins(:user).where(published: true).order(created_at: :desc)
Post.join(:users) { |on| on.posts.user_id == on.users.id }

User.preload(:posts).all.each { |user| puts user.posts.size }

User.exists?(email: "alice@example.com")
User.where(role: "admin").any?
User.where(role: "banned").empty?
User.none.all
```

## Batch processing

`find_each(batch_size = 1000)` yields records, `find_in_batches(batch_size = 1000)` yields arrays. There is no
`in_batches`.


## Bulk writes

These issue a single statement and do not validate or run callbacks (except `delete_all` on a query, which loads each
record and calls `delete!`):

| Method | Description |
| --- | --- |
| `User.update_by(where_attrs, update_attrs)` | `UPDATE ... WHERE`; both arguments are `Hash(Symbol, DB::Any)` |
| `User.update_all(attrs)` | updates every row |
| `User.delete_by!(**attrs)` | `DELETE ... WHERE` |
| `query.delete_all` | loads the matches and calls `delete!` on each |


## Scopes

`scope` defines a named query on the class. It may take arguments and chains with other scopes and builder methods.


## Locking

On PostgreSQL, CockroachDB and MySQL `with_query(&.lock)` appends `FOR UPDATE`; `lock(:share)`, `skip_locked: true` and
`nowait: true` adjust it. SQLite raises `CQL::DialectError`.


## Inspecting the SQL

`to_sql` returns the statement and `to_sql_with_params` the statement with its bound values.

### Examples

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
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
  db_context MyDB, :posts

  property user_id : Int64
  property title : String
  property published : Bool = false
  property views : Int32 = 0
  property created_at : Time?

  belongs_to :user, User, :user_id

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id : Int64) { where(user_id: user_id) }

  def initialize(@user_id : Int64, @title : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property name : String
  property email : String
  property age : Int32?
  property role : String = "user"
  property active : Bool = true
  property deleted_at : Time?
  property created_at : Time?

  has_many :posts, Post, foreign_key: :user_id

  scope :active, -> { where(active: true) }
  scope :with_role, ->(role : String) { where(role: role) }

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

User.find_each(batch_size: 1000) { |user| puts user.email }
User.where(active: true).find_in_batches(batch_size: 500) { |batch| puts batch.size }

User.update_by({:role => "user".as(DB::Any)}, {:active => false.as(DB::Any)})
User.delete_by!(role: "banned")
User.where(active: false).delete_all

User.active.with_role("admin").order(name: :asc).limit(10).all
Post.published.recent.by_user(1_i64).count

User.where(id: 1_i64).with_query(&.lock).first
User.where(role: "worker").with_query(&.lock(skip_locked: true)).all

sql, params = User.where(role: "admin").limit(5).to_sql_with_params
```

## Raw SQL

`schema.exec_query` yields a `DB::Connection` that takes parameters; `schema.exec` takes one SQL string and no
parameters.


## Chaining

All builder methods chain.

### Examples

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
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
  db_context MyDB, :posts

  property user_id : Int64
  property title : String
  property published : Bool = false
  property views : Int32 = 0
  property created_at : Time?

  belongs_to :user, User, :user_id

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id : Int64) { where(user_id: user_id) }

  def initialize(@user_id : Int64, @title : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property name : String
  property email : String
  property age : Int32?
  property role : String = "user"
  property active : Bool = true
  property deleted_at : Time?
  property created_at : Time?

  has_many :posts, Post, foreign_key: :user_id

  scope :active, -> { where(active: true) }
  scope :with_role, ->(role : String) { where(role: role) }

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

names = MyDB.exec_query { |connection| connection.query_all("SELECT name FROM users WHERE age > ?", 18, as: String) }

MyDB.exec_query { |connection| connection.exec("UPDATE users SET active = ? WHERE id = ?", true, 1) }

MyDB.exec("DELETE FROM users WHERE active = 0")

User.where(active: true)
  .where("age >= ?", 18)
  .order(name: :asc)
  .limit(10)
  .offset(20)
  .all
```

## See also

- [CQL API](cql-api.md)
- [Query data](../../how-to/database/query-data.md)
- [CQL bridge](../api/cql-bridge.md)

# CQL API

CQL (Crystal Query Language) is the ORM used with Azu for database operations. It is a separate shard
([`azutoolkit/cql`](https://github.com/azutoolkit/cql)): add `cql` and a driver shard (`sqlite3`, `pg` or `mysql`) to your
`shard.yml`. Azu core does not depend on it; the optional bridge `require "azu/cql"` connects CQL to the dev dashboard
(see [Database dashboard](../database-dashboard.md)).

This page describes CQL 0.0.766, the release Azu's `shard.lock` pins (its `shard.yml` accepts `cql >= 0.0.609`). For task-oriented guides see
[Define Schema](../../how-to/database/define-schema.md), [Create Models](../../how-to/database/create-models.md),
[Query Data](../../how-to/database/query-data.md), [Handle Transactions](../../how-to/database/handle-transactions.md)
and [Run Migrations](../../how-to/database/run-migrations.md).

## Schema Definition

### CQL::Schema.define

Creates a schema bound to a database. The block declares tables; the schema opens the connection pool right away
(append `?initial_pool_size=0` to the URI to connect on first use):

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(
  :my_db,
  adapter: CQL::Adapter::SQLite,
  uri: "sqlite3://./db/development.db"
) do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    timestamps
  end
end

MyDB.build   # CREATE TABLE IF NOT EXISTS for every table
```

**Parameters:**

- `name : Symbol` - schema name
- `adapter : CQL::Adapter` - `SQLite`, `Postgres`, `MySql` or `CockroachDB`
- `uri : String` - connection string
- `version : String` - free-form schema version (default `"1.0"`)
- `quote_identifiers : Bool` - quote table and column names (default `false`)

## Adapters

| Adapter | URI Format | Driver shard |
| --- | --- | --- |
| `CQL::Adapter::SQLite` | `sqlite3://./path/to/db.db` | `sqlite3` |
| `CQL::Adapter::Postgres` | `postgres://user:pass@host:5432/db` | `pg` |
| `CQL::Adapter::MySql` | `mysql://user:pass@host:3306/db` | `mysql` |
| `CQL::Adapter::CockroachDB` | `postgres://user@host:26257/db` | `pg` |

The URI query string carries crystal-db pool options such as `initial_pool_size`, `max_pool_size` and
`checkout_timeout`.

## Table Definition

Inside `table :name do ... end`:

| Method | Description |
| --- | --- |
| `primary :id, Int64` | primary key; `Int32`, `Int64` or `UUID`; auto increment for integers |
| `column :name, Type, null:, default:, unique:, size:, as:` | a column of any supported Crystal type |
| `integer`, `bigint`, `float`, `double`, `real`, `text`, `varchar`, `boolean`, `timestamp`, `date`, `json`, `interval`, `blob` | typed shortcuts taking the same options |
| `timestamps` | `created_at` and `updated_at`, `NOT NULL` with a database default |
| `lock_version :version` | integer column for optimistic locking |
| `foreign_key :user_id, references: :users, on_delete: :cascade` | foreign key (`:no_action`, `:cascade`, `:restrict`, `:set_null`, `:set_default`) |
| `unique_constraint [:a, :b]`, `check_constraint "price > 0"` | table constraints |

**Column types:** `String`, `Int32`, `Int64`, `UInt32`, `UInt64`, `Float32`, `Float64`, `Bool`, `Time`, `Time::Span`,
`JSON::Any`, `Slice(UInt8)`, `UUID`. Columns are `NOT NULL` unless `null: true`; `default:` takes a literal value.

`index [:a, :b], unique:, name:` and a column's `index: true` declare an index; `create!` and `Schema#build` create it
after the table, named `idx_<table>_<columns>` unless `name:` is given.

## Model Definition

### CQL::ActiveRecord::Model

Include the module with the primary key type and point the class at a table with `db_context`:

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :active, Bool, default: true
    timestamps
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property name : String
  property email : String
  property active : Bool = true
  property created_at : Time?
  property updated_at : Time?

  def initialize(@name : String, @email : String)
  end
end

User.schema    # => MyDB
User.table     # => :users
```

`CQL::Model` is an alias of `CQL::ActiveRecord::Model`. The type argument is the primary key type (`Int32`, `Int64`,
`UUID`); the model gets `id : Pk?`, `id!`, `persisted?` and `new_record?`. Use `class`, not `struct`.

## CRUD Operations

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :active, Bool, default: true
    timestamps
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property name : String
  property email : String
  property active : Bool = true
  property created_at : Time?
  property updated_at : Time?

  validate :name, presence: true

  def initialize(@name : String, @email : String)
  end
end

# Create
user = User.new("Alice", "alice@example.com")
user.save                                       # validates, runs callbacks, INSERTs; Bool
user.save!                                      # same, raises instead of returning false
created = User.create!(name: "Bob", email: "bob@example.com")   # INSERT only, see below

# Read
User.find(1_i64)                                # User? (find? is the same)
User.find!(1_i64)                               # User, raises DB::NoResultsError
User.find_by(email: "alice@example.com")        # User?
User.find_by!(email: "alice@example.com")       # User, raises DB::NoResultsError
User.find_or_create_by(name: "Carol", email: "carol@example.com")

# Update
user.name = "Alice Smith"
user.save!                                      # persisted record: UPDATE
user.update!(name: "Alice S.")                  # assigns and UPDATEs, no validation
user.touch                                      # sets updated_at
user.reload!                                    # re-reads the row

# Delete
user.delete!                                    # Bool; runs before/after_destroy callbacks
User.delete!(2_i64)                             # by id
User.delete_by!(active: false)                  # by attributes
User.where(active: false).delete_all            # loads and delete!s each record
```

**`create!(**fields)` and `update!` write straight to the database**: they do not validate and do not run callbacks.
Build the record with `new` and call `save`/`save!` for the full lifecycle. `save`, `save!` and the instance `create!`
raise `CQL::ActiveRecord::Validations::ValidationError` for an invalid record; `save` returns `false` only when a
callback returns `false`.

## Query Methods

Model-level methods start a `QueryBuilder`; the complete list with examples is in
[Query Methods Reference](query-methods.md):

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :age, Int32, null: true
    column :active, Bool, default: true
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property name : String
  property age : Int32?
  property active : Bool = true

  def initialize(@name : String)
  end
end

User.all
User.where(active: true).all
User.where("age > ?", 18).all
User.order(name: :asc).limit(10).offset(20).all
User.count
User.first
User.where(name: "Alice").exists?
```

## Associations

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :users do
    primary :id, Int64
    column :name, String
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
  end

  table :profiles do
    primary :id, Int64
    column :user_id, Int64
    column :bio, String
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :posts

  property user_id : Int64
  property title : String

  belongs_to :user, User, :user_id            # (association, class, foreign key; optional: true by default)

  def initialize(@title : String, @user_id : Int64 = 0_i64)
  end
end

class Profile
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :profiles

  property user_id : Int64
  property bio : String

  def initialize(@user_id : Int64, @bio : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property name : String

  has_many :posts, Post, foreign_key: :user_id
  has_one :profile, Profile, foreign_key: :user_id

  def initialize(@name : String)
  end
end

user = User.find!(1_i64)
user.posts.to_a                    # Array(Post)
user.posts.build(title: "Draft")   # Post with user_id set, not saved
user.profile                       # Profile?
Post.find!(1_i64).user             # User?
```

- `has_many name, Class, foreign_key:, dependent:, inverse_of:, scope:` gives a collection with `to_a`, `each`, `size`,
  `count`, `empty?`, `first`, `last`, `build`, `create`, `where`, `limit`, `order`, `delete` and `ids`.
- `has_one name, Class, foreign_key:, dependent:, cache:` adds `name`, `name=`, `build_name`, `create_name`.
- `belongs_to assoc, Class, foreign_key, optional:, cache:` adds `assoc`, `assoc=`, `build_assoc`, `create_assoc`.
- `many_to_many name, Class, join_through: JoinModel, foreign_key:, association_foreign_key:` adds the collection and
  `name_ids`, `name_count`, `add_<singular>`, `remove_<singular>`.
- `delete!` applies `dependent:` in the same transaction as the record's own delete. `has_many` takes `:destroy`,
  `:delete_all`, `:nullify` or `:restrict_with_error` (`delete!` raises `RelationError` and deletes nothing while
  records exist); `has_one` takes `:destroy`, `:delete` or `:nullify`.
- A collection's `where`, `limit` and `order` return a `CQL::Query`: finish with `.all(Post)`.

## Callbacks

`before_validation`, `after_validation`, `before_save`, `after_save`, `before_create`, `after_create`, `before_update`,
`after_update`, `before_destroy`, `after_destroy`. Each takes a method name; returning `false` halts the operation:

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :users do
    primary :id, Int64
    column :email, String
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property email : String

  before_save :normalize_email
  after_create :send_welcome_email

  def initialize(@email : String)
  end

  private def normalize_email
    @email = email.downcase.strip
    true
  end

  private def send_welcome_email
    Log.info { "welcome #{email}" }
    true
  end
end

User.new(" Alice@Example.com ").save!
```

## Scopes

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :role, String, default: "user"
    column :active, Bool, default: true
    timestamps
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property name : String
  property role : String = "user"
  property active : Bool = true
  property created_at : Time?

  scope :active, -> { where(active: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :with_role, ->(role : String) { where(role: role) }

  def initialize(@name : String)
  end
end

User.active.recent.all
User.with_role("admin").count
```

## Validations

`validate :attribute, rule: value, message: "..."` with the rules `presence`, `required`, `size`, `match`, `gt`, `gte`,
`lt`, `lte`, `eq`, `in`, `exclude`, `confirmation`, `accept`; `use CustomValidator` for the rest. See
[Validations Reference](validations.md).

## Transactions

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :users do
    primary :id, Int64
    column :name, String
  end

  table :profiles do
    primary :id, Int64
    column :user_id, Int64
    column :bio, String
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :users

  property name : String

  def initialize(@name : String)
  end
end

class Profile
  include CQL::ActiveRecord::Model(Int64)
  db_context MyDB, :profiles

  property user_id : Int64
  property bio : String

  def initialize(@user_id : Int64, @bio : String)
  end
end

user = MyDB.transaction do |tx|
  created = User.create!(name: "Alice")
  Profile.create!(user_id: created.id!, bio: "Hello")
  created                         # the block's value is returned
end

User.transaction do |outer|       # Model.transaction is schema.transaction
  User.transaction(outer) do |_inner|   # a savepoint
    raise DB::Rollback.new        # rolls back the savepoint only
  end
end
```

An exception rolls back and propagates; `DB::Rollback` rolls back quietly and the call returns `nil`. There are no
isolation-level or read-only options and no `after_commit`; see
[Handle Transactions](../../how-to/database/handle-transactions.md).

## Raw Queries

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :age, Int32
    column :active, Bool, default: true
  end
end

# Parameters go through the connection
adults = MyDB.exec_query do |connection|
  connection.query_all("SELECT name FROM users WHERE age > ?", 18, as: String)
end

MyDB.exec_query do |connection|
  connection.exec("UPDATE users SET active = ? WHERE id = ?", true, 1)
end

# schema.exec runs one statement and takes no parameters
MyDB.exec("DELETE FROM users WHERE active = 0")

# The query builder works without a model
names = MyDB.query.from(:users).select(:name).where(active: true).all(as: {String})
```

## Optional Modules

```crystal
require "cql"
require "sqlite3"

MyDB = CQL::Schema.define(:my_db, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :documents do
    primary :id, Int64
    column :title, String
    column :deleted_at, Time, null: true
  end

  table :counters do
    primary :id, Int64
    column :name, String
    lock_version :lock_version
  end
end

class Document
  include CQL::ActiveRecord::Model(Int64)
  include CQL::ActiveRecord::SoftDeletable   # delete! sets deleted_at; queries skip deleted rows
  db_context MyDB, :documents

  property title : String

  def initialize(@title : String)
  end
end

class Counter
  include CQL::ActiveRecord::Model(Int64)
  include CQL::ActiveRecord::OptimisticLocking
  db_context MyDB, :counters

  property name : String
  property lock_version : Int32 = 1

  optimistic_locking :lock_version

  def initialize(@name : String)
  end
end

document = Document.find!(1_i64)
document.delete!          # soft delete
document.restore!         # undo
document.force_delete!    # really DELETE
Document.with_deleted
Document.only_deleted
```

## Configuration

`CQL.configure` sets library-wide options (URL, logging, pool). With `require "azu/cql"` use `Azu::CQL.configure`, which
also installs the dashboard instrumentation:

```crystal
require "cql"

CQL.configure do |config|
  config.db = ENV.fetch("DATABASE_URL", "sqlite3://./db/development.db")
  config.sql_logging = true
  config.pool_size = 10
end
```

## Errors

| Error | Raised when |
| --- | --- |
| `DB::NoResultsError` | `find!`, `find_by!` and `first!` found nothing |
| `CQL::ActiveRecord::Validations::ValidationError` | `save`, `save!`, `validate!` on an invalid record |
| `CQL::RecordInvalid`, `CQL::RecordNotSaved` | defined by CQL for failed saves; `save!` raises them only in rare paths |
| `CQL::DialectError` | SQL the dialect cannot express (for example `FOR UPDATE` on SQLite) |
| `CQL::Migrator::Error` | migration failures |
| `DB::Error` and subclasses | driver errors: constraint violations, lost connections |

With `require "azu/cql"`, `model.valid_or_422!` raises `Azu::Response::ValidationError` (422) for an invalid record,
and `Azu::CQL::Middleware` turns an escaping `CQL::RecordInvalid`, `CQL::ValidationError` or model validation error
into that 422 (see [CQL bridge](../api/cql-bridge.md)). Azu translates no other CQL error: rescue it in the endpoint
(or a handler) and raise an `Azu::Response` error, for example `Azu::Response::NotFound` when `find` returns `nil`;
see [Working with Databases](../../tutorials/working-with-databases.md).

## See Also

- [Query Methods Reference](query-methods.md)
- [Validations Reference](validations.md)
- [How to Create Models](../../how-to/database/create-models.md)

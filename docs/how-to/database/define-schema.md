# Define a schema

This guide shows you how to describe your database with CQL's schema DSL.

CQL is a separate shard. Azu core does not depend on it, so add `cql` and a database driver (`sqlite3`, `pg` or
`mysql`) to your `shard.yml` and `require` them before the schema file. To see queries in the dev dashboard, also
`require "azu/cql"` (see [Database dashboard](../../reference/database-dashboard.md)).

## Basic Schema Definition

`CQL::Schema.define` takes a name, the adapter and the connection URI, and yields a block where tables are declared:

```crystal
require "cql"
require "sqlite3"

# src/db/schema.cr
AppDB = CQL::Schema.define(
  :app,
  adapter: CQL::Adapter::SQLite,
  uri: ENV.fetch("DATABASE_URL", "sqlite3://./db/development.db")
) do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String, unique: true
    timestamps
  end
end

AppDB.build # CREATE TABLE IF NOT EXISTS for every table in the schema
```

`build` runs `CREATE TABLE IF NOT EXISTS` for each table. For changes to existing databases use
[migrations](run-migrations.md).

## Column Types

`column name, Type` accepts the Crystal types below. Every column is `NOT NULL` unless you pass `null: true`;
there is no `String?` shorthand, nullability is a column option.

| Crystal type | Typed helper | SQL (SQLite / PostgreSQL) |
| --- | --- | --- |
| `Int32` | `integer` | INTEGER |
| `Int64` | `bigint` | INTEGER / BIGINT |
| `Float32` | `float` | REAL |
| `Float64` | `double`, `real` | DOUBLE / DOUBLE PRECISION |
| `String` | `text`, `varchar` | TEXT / VARCHAR |
| `Bool` | `boolean` | BOOLEAN |
| `Time` | `timestamp`, `date` | DATE / TIMESTAMP |
| `JSON::Any` | `json` | TEXT / JSONB |
| `Slice(UInt8)` | `blob` | BLOB / BYTEA |
| `Time::Span` | `interval` | INTERVAL |

```crystal
require "cql"
require "sqlite3"

ProductsDB = CQL::Schema.define(:products, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/products.db") do
  table :products do
    primary :id, Int64
    column :name, String
    column :description, String, null: true
    column :price, Float64
    column :quantity, Int32, default: 0
    column :active, Bool, default: true
    column :metadata, JSON::Any, null: true
    text :sku, unique: true
    varchar :category, size: 50
    timestamps
  end
end
```

Column options: `null:`, `default:` (a literal value, not a block), `unique:`, `size:`, `as:` (a different name in
the database) and `index: true` (an index on the column; see [Indexes](#indexes)).

### Primary Keys

`primary` takes the column name and a key type (`Int32`, `Int64` or `UUID`). Integer keys auto increment:

```crystal
require "cql"
require "sqlite3"

IdsDB = CQL::Schema.define(:ids, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/ids.db") do
  table :accounts do
    primary :id, Int64
    column :name, String
  end

  table :sessions do
    primary :id, UUID
    column :account_id, Int64
  end
end
```

### Timestamps

`timestamps` adds `created_at` and `updated_at`, both `NOT NULL` with the database's current time as default.

## Foreign Keys

`foreign_key` takes the local column and the table it references (the referenced column defaults to the other
table's primary key). `on_delete:` and `on_update:` accept `:no_action`, `:cascade`, `:restrict`, `:set_null` and
`:set_default`:

```crystal
require "cql"
require "sqlite3"

BlogDB = CQL::Schema.define(:blog, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/blog.db") do
  table :users do
    primary :id, Int64
    column :name, String
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
    column :content, String
    column :published, Bool, default: false
    timestamps

    foreign_key :user_id, references: :users, on_delete: :cascade
  end
end
```

### Join Tables

A composite foreign key pair needs one `foreign_key` per column:

```crystal
require "cql"
require "sqlite3"

TagsDB = CQL::Schema.define(:tags, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/tags.db") do
  table :posts do
    primary :id, Int64
    column :title, String
  end

  table :tags do
    primary :id, Int64
    column :name, String
  end

  table :post_tags do
    primary :id, Int64
    column :post_id, Int64
    column :tag_id, Int64

    foreign_key :post_id, references: :posts, on_delete: :cascade
    foreign_key :tag_id, references: :tags, on_delete: :cascade
    unique_constraint [:post_id, :tag_id]
  end
end
```

## Constraints

`unique_constraint` and `check_constraint` become part of `CREATE TABLE`:

```crystal
require "cql"
require "sqlite3"

ShopDB = CQL::Schema.define(:shop, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/shop.db") do
  table :orders do
    primary :id, Int64
    column :number, String
    column :organization_id, Int64
    column :total, Float64

    unique_constraint [:organization_id, :number], name: "uk_orders_number"
    check_constraint "total >= 0", name: "chk_orders_total"
  end
end
```

## Indexes

`index [...]` and the `index: true` column option declare an index that `build` (and `create!` in a migration)
creates right after the table, with `CREATE INDEX IF NOT EXISTS`. The name is `idx_<table>_<columns>` unless you pass
`name:` to `index`. A `unique: true` column option is a `UNIQUE` constraint, so it is indexed too. To add an index to a table
that already exists, use `schema.alter`, which runs immediately, or a [migration](run-migrations.md).

```crystal
require "cql"
require "sqlite3"

IndexedDB = CQL::Schema.define(:indexed, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/indexed.db") do
  table :users do
    primary :id, Int64
    column :email, String, unique: true
    column :organization_id, Int64, index: true
    column :username, String
    index [:organization_id, :username], unique: true
  end
end

# CREATE TABLE, then idx_users_organization_id and the unique idx_users_organization_id_username
IndexedDB.build

IndexedDB.alter(:users) do
  create_index :index_users_on_username, [:username]
end
```

## Multiple Tables

Declare every table of the application in one schema, parents before children:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String, unique: true
    timestamps
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
    column :content, String
    column :published, Bool, default: false
    timestamps

    foreign_key :user_id, references: :users, on_delete: :cascade
  end

  table :comments do
    primary :id, Int64
    column :post_id, Int64
    column :user_id, Int64
    column :content, String
    timestamps

    foreign_key :post_id, references: :posts, on_delete: :cascade
    foreign_key :user_id, references: :users
  end
end
```

CQL can also dump a schema file from the live database after migrations (`CQL::Migrator` with `auto_sync`, see
[Run Migrations](run-migrations.md)).

## Database Adapters

The adapter decides the SQL dialect; the URI selects the driver.

### SQLite

```crystal
require "cql"
require "sqlite3"

SqliteDB = CQL::Schema.define(:app, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/app.db") do
  table :notes do
    primary :id, Int64
    column :body, String
  end
end
```

### PostgreSQL

```crystal
require "cql"
require "pg"

PgDB = CQL::Schema.define(:app, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_URL"]) do
  table :notes do
    primary :id, Int64
    column :body, String
  end
end
```

`CQL::Adapter::CockroachDB` works the same way with the `pg` driver.

### MySQL

Add the `mysql` shard and `require "mysql"` before the schema:

```crystal
require "cql"

MysqlDB = CQL::Schema.define(:app, adapter: CQL::Adapter::MySql, uri: ENV["DATABASE_URL"]) do
  table :notes do
    primary :id, Int64
    column :body, String
  end
end
```

## Environment-based Configuration

Pick the URI from `CRYSTAL_ENV` (the variable Azu's `Azu::Environment` reads):

```crystal
require "cql"
require "sqlite3"

def database_uri : String
  case ENV.fetch("CRYSTAL_ENV", "development")
  when "production"
    ENV["DATABASE_URL"]
  when "test"
    "sqlite3://./db/test.db"
  else
    "sqlite3://./db/development.db"
  end
end

AppDB = CQL::Schema.define(:app, adapter: CQL::Adapter::SQLite, uri: database_uri) do
  table :users do
    primary :id, Int64
    column :name, String
  end
end
```

With `require "azu/cql"`, `Azu::CQL.schema` picks the adapter from the URL scheme and configures the connection
pool; see [Database dashboard](../../reference/database-dashboard.md).

## See Also

- [Create Models](create-models.md)
- [Run Migrations](run-migrations.md)

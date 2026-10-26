---
description: Describe your database with CQL's schema DSL.
---

# Define a schema

The schema names the tables and columns CQL knows about and holds the connection pool. Models point at its tables
with `db_context`, and migrations change the tables it declares.

Before you start: a project made by `azu new`, or `cql` and a database driver shard (`sqlite3`, or `mysql`; PostgreSQL
needs none) in your `shard.yml`.

## The schema file

`azu new` writes the connection settings to `src/initializers/cql_config.cr` and the schema to `src/db/schema.cr`:

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
    text :email, unique: true
    timestamps
  end
end
```

`Azu::CQL.schema` takes the schema's name and a block that declares the tables. The URL comes from
`Azu::CQL.configure`, the adapter from the URL's scheme (`sqlite3://`, `postgres://`, `mysql://`), and the schema is
attached to the dev dashboard's Database tab. It connects on the first query, so the app boots without a database. The
generated file also declares `cql_schema_migrations`, the table the migrator records applied migrations in, and
`azu generate model` adds the table of each model it creates.

Migrations create the tables (see [Run migrations](run-migrations.md)). `build` runs `CREATE TABLE IF NOT EXISTS` for
every declared table, which suits tests and scripts:

```crystal
AcmeDB.build
```

## Column types

`column name, Type` accepts the Crystal types below, and each has a typed helper. Every column is `NOT NULL` unless you
pass `null: true`; there is no `String?` shorthand, nullability is a column option.

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
ProductsDB = Azu::CQL.schema :products do
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

### Primary keys

`primary` takes the column name and a key type (`Int32`, `Int64` or `UUID`). Integer keys auto increment:

```crystal
IdsDB = Azu::CQL.schema :ids do
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

## Foreign keys

`foreign_key` takes the local column and the table it references (the referenced column defaults to the other
table's primary key). `on_delete:` and `on_update:` accept `:no_action`, `:cascade`, `:restrict`, `:set_null` and
`:set_default`. Declare parent tables before their children:

```crystal
BlogDB = Azu::CQL.schema :blog do
  table :authors do
    primary :id, Int64
    column :name, String
  end

  table :posts do
    primary :id, Int64
    column :author_id, Int64
    column :title, String
    column :content, String
    column :published, Bool, default: false
    timestamps

    foreign_key :author_id, references: :authors, on_delete: :cascade
  end

  table :comments do
    primary :id, Int64
    column :post_id, Int64
    column :author_id, Int64
    column :content, String
    timestamps

    foreign_key :post_id, references: :posts, on_delete: :cascade
    foreign_key :author_id, references: :authors
  end
end
```

SQLite enforces foreign keys only with `PRAGMA foreign_keys = ON`; `Azu::CQL.schema` sets it on every SQLite
connection (opt out with `c.sqlite.foreign_keys = false` in `Azu::CQL.configure`).

### Join tables

A composite foreign key pair needs one `foreign_key` per column:

```crystal
TagsDB = Azu::CQL.schema :tags do
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
ShopDB = Azu::CQL.schema :shop do
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
IndexedDB = Azu::CQL.schema :indexed do
  table :members do
    primary :id, Int64
    column :email, String, unique: true
    column :organization_id, Int64, index: true
    column :username, String
    index [:organization_id, :username], unique: true
  end
end

# CREATE TABLE, then idx_members_organization_id and the unique idx_members_organization_id_username
IndexedDB.build

IndexedDB.alter(:members) do
  create_index :index_members_on_username, [:username]
end
```

## Database adapters

The URL picks the adapter. Set it in `src/initializers/cql_config.cr`, or leave the code alone and set `DATABASE_URL`:

{% tabs %}
{% tab title="SQLite" %}
`require "sqlite3"` and add the `sqlite3` shard:

```crystal
Azu::CQL.configure do |c|
  c.db = ENV["DATABASE_URL"]? || "sqlite3://./db/acme_development.db"
end
```
{% endtab %}

{% tab title="PostgreSQL" %}
A `postgres://` or `postgresql://` URL runs on CQL's own PostgreSQL engine, so no driver shard is needed:

```crystal
Azu::CQL.configure do |c|
  c.db = ENV["DATABASE_URL"]? || "postgres://localhost/acme_development"
  c.pool.size = 10
end
```

`Azu::CQL.schema(:acme, driver: :db)` (or `AZU_CQL_DRIVER=db`) uses crystal-db's pool and the `pg` shard instead;
see [Database dashboard](../../reference/database-dashboard.md) for the pool settings.
{% endtab %}

{% tab title="MySQL" %}
Add the `mysql` shard and `require "mysql"` in place of `sqlite3`:

```crystal
Azu::CQL.configure do |c|
  c.db = ENV["DATABASE_URL"]? || "mysql://root@localhost/acme_development"
end
```
{% endtab %}
{% endtabs %}

## Environment-based configuration

`azu new` puts the environment in the default URL and writes `DATABASE_URL` for development and test to
`.env.development` and `.env.test`, which the app loads at boot (see
[Azu::Env](../../reference/configuration/env.md)). A `DATABASE_URL` set in the process environment wins over both:

```crystal
Azu::CQL.configure do |c|
  c.db = ENV["DATABASE_URL"]? || "sqlite3://./db/acme_#{ENV["CRYSTAL_ENV"]? || "development"}.db"
end
```

## Without Azu

Code that does not load `azu/cql` (a script, a shard) defines the schema with CQL itself. `CQL::Schema.define` takes
the adapter and the URL explicitly, opens the pool right away (append `?initial_pool_size=0` to connect on first use)
and applies none of the SQLite settings above:

```crystal
require "cql"
require "sqlite3"

ScriptDB = CQL::Schema.define(:script, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
  end
end
```

`Azu::CQL.attach(ScriptDB)` shows such a schema in the dev dashboard. The schema file the migrator writes with
`auto_sync` on has this form too (see [Run migrations](run-migrations.md#schema-file-synchronisation)).

## See also

- [Create models](create-models.md)
- [Run migrations](run-migrations.md)
- [Database dashboard](../../reference/database-dashboard.md)
- [CQL API](../../reference/database/cql-api.md)

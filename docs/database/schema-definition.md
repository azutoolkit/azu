# Schema Definition

CQL schemas define your database structure declaratively with type-safe column definitions.

## Defining a Schema

```crystal
require "cql"

AppDB = CQL::Schema.define(
  :app_database,
  adapter: CQL::Adapter::Postgres,
  uri: ENV["DATABASE_URL"]
) do
  table :users do
    primary :id, Int64
    text :name
    text :email
    integer :age, null: true
    boolean :active, default: "true"
    timestamps
  end
end
```

## Adapters

Configure the database adapter based on your database:

```crystal
# PostgreSQL
adapter: CQL::Adapter::Postgres

# MySQL
adapter: CQL::Adapter::MySQL

# SQLite
adapter: CQL::Adapter::SQLite
```

## Connection URI

Use environment variables for database connections:

```crystal
# From environment variable
uri: ENV["DATABASE_URL"]

# Direct connection string
uri: "postgres://user:pass@localhost:5432/myapp_development"
```

## Column Types

| Method | Crystal Type | SQL Type |
|--------|--------------|----------|
| `primary :id, Int64` | `Int64` | `BIGSERIAL PRIMARY KEY` |
| `primary :id, UUID` | `UUID` | `UUID PRIMARY KEY` |
| `text :name` | `String` | `TEXT` / `VARCHAR` |
| `integer :count` | `Int32` | `INTEGER` |
| `bigint :amount` | `Int64` | `BIGINT` |
| `boolean :active` | `Bool` | `BOOLEAN` |
| `float :price` | `Float64` | `DOUBLE PRECISION` |
| `timestamp :published_at` | `Time` | `TIMESTAMP` |
| `date :birth_date` | `Time` | `DATE` |

## Column Options

```crystal
table :products do
  primary :id, Int64

  # Required column (NOT NULL)
  text :name

  # Nullable column
  text :description, null: true

  # Default value
  boolean :active, default: "true"
  integer :stock, default: "0"

  # Auto-generated timestamps
  timestamps  # Creates created_at and updated_at
end
```

## Indexes

```crystal
table :users do
  primary :id, Int64
  text :email
  text :username
  bigint :company_id

  # Unique index
  index :email, unique: true

  # Regular index
  index :company_id

  # Composite index
  index [:company_id, :username]
end
```

## Foreign Keys

```crystal
table :posts do
  primary :id, Int64
  text :title
  bigint :user_id
  bigint :category_id, null: true

  # Foreign key indexes
  index :user_id
  index :category_id
end
```

## Complete Example

```crystal
AppDB = CQL::Schema.define(
  :blog,
  adapter: CQL::Adapter::Postgres,
  uri: ENV["DATABASE_URL"]
) do
  table :users do
    primary :id, Int64
    text :username
    text :email
    text :password_digest
    boolean :admin, default: "false"
    boolean :active, default: "true"
    timestamps

    index :email, unique: true
    index :username, unique: true
  end

  table :posts do
    primary :id, Int64
    text :title
    text :content
    text :slug
    bigint :user_id
    boolean :published, default: "false"
    timestamp :published_at, null: true
    timestamps

    index :user_id
    index :slug, unique: true
    index :published
  end

  table :comments do
    primary :id, Int64
    text :body
    bigint :post_id
    bigint :user_id
    timestamps

    index :post_id
    index :user_id
  end
end
```

## Next Steps

- [Models](models.md) - Define model structs that map to tables
- [Migrations](migrations.md) - Manage schema changes over time

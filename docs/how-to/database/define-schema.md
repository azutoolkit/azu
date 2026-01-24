# How to Define a Schema

This guide shows you how to define your database schema using CQL.

## Basic Schema Definition

Create a schema file:

```crystal
# src/db/schema.cr
AcmeDB = CQL::Schema.define(
  :acme_db,
  adapter: CQL::Adapter::SQLite,
  uri: ENV.fetch("DATABASE_URL", "sqlite3://./db/development.db")
) do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :created_at, Time, default: -> { Time.utc }
    column :updated_at, Time, default: -> { Time.utc }
  end
end
```

## Column Types

### Basic Types

```crystal
table :products do
  primary :id, Int64
  column :name, String                    # VARCHAR/TEXT
  column :description, String?            # Nullable
  column :price, Float64                  # REAL/DOUBLE
  column :quantity, Int32                 # INTEGER
  column :active, Bool, default: true     # BOOLEAN
  column :metadata, JSON::Any?            # JSON
end
```

### Timestamps

```crystal
table :posts do
  primary :id, Int64
  column :title, String
  timestamps  # Adds created_at and updated_at
end
```

### Custom Defaults

```crystal
table :orders do
  primary :id, Int64
  column :status, String, default: "pending"
  column :order_number, String, default: -> { generate_order_number }
  column :created_at, Time, default: -> { Time.utc }
end
```

## Relationships

### Foreign Keys

```crystal
table :posts do
  primary :id, Int64
  column :user_id, Int64
  column :title, String
  column :content, String

  foreign_key :user_id, :users, :id
end
```

### Join Tables

```crystal
table :post_tags do
  primary :id, Int64
  column :post_id, Int64
  column :tag_id, Int64

  foreign_key :post_id, :posts, :id
  foreign_key :tag_id, :tags, :id

  index [:post_id, :tag_id], unique: true
end
```

## Indexes

```crystal
table :users do
  primary :id, Int64
  column :email, String
  column :username, String
  column :organization_id, Int64

  index :email, unique: true
  index :username, unique: true
  index :organization_id  # Non-unique index
  index [:organization_id, :username], unique: true  # Composite
end
```

## Multiple Tables

```crystal
AcmeDB = CQL::Schema.define(:acme_db, adapter: CQL::Adapter::SQLite, uri: db_uri) do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    timestamps
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
    column :content, String
    column :published, Bool, default: false
    timestamps

    foreign_key :user_id, :users, :id
    index :user_id
  end

  table :comments do
    primary :id, Int64
    column :post_id, Int64
    column :user_id, Int64
    column :content, String
    timestamps

    foreign_key :post_id, :posts, :id
    foreign_key :user_id, :users, :id
  end
end
```

## Database Adapters

### SQLite

```crystal
CQL::Schema.define(:mydb, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/app.db")
```

### PostgreSQL

```crystal
CQL::Schema.define(:mydb, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_URL"])
```

### MySQL

```crystal
CQL::Schema.define(:mydb, adapter: CQL::Adapter::MySql, uri: ENV["DATABASE_URL"])
```

## Environment-based Configuration

```crystal
def database_uri
  case ENV.fetch("AZU_ENV", "development")
  when "production"
    ENV["DATABASE_URL"]
  when "test"
    "sqlite3://./db/test.db"
  else
    "sqlite3://./db/development.db"
  end
end

AcmeDB = CQL::Schema.define(:acme_db, adapter: CQL::Adapter::SQLite, uri: database_uri)
```

## See Also

- [Create Models](create-models.md)
- [Run Migrations](run-migrations.md)

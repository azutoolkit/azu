# CQL Overview

CQL (Crystal Query Language) is a type-safe ORM for Crystal applications that provides compile-time query validation and high-performance database operations.

## Why CQL with Azu?

- **Type Safety**: Queries are validated at compile time, catching errors before runtime
- **Performance**: Zero-allocation queries with Crystal's compile-time optimizations
- **Integration**: Works seamlessly with Azu's request/response contracts
- **Monitoring**: Built-in N+1 detection integrated with Azu's development dashboard

## Installation

Add CQL and a database driver to your `shard.yml`:

```yaml
dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.28
  cql:
    github: azutoolkit/cql
    version: ~> 0.1.0
```

Add your database driver:

```yaml
# PostgreSQL (recommended for production)
dependencies:
  pg:
    github: will/crystal-pg

# MySQL
dependencies:
  mysql:
    github: crystal-lang/crystal-mysql

# SQLite (development/testing)
dependencies:
  sqlite3:
    github: crystal-lang/crystal-sqlite3
```

Run `shards install` to fetch dependencies.

## Quick Start

### 1. Define Schema

```crystal
# src/config/database.cr
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
    boolean :active, default: "true"
    timestamps
    index :email, unique: true
  end

  table :posts do
    primary :id, Int64
    text :title
    text :content
    bigint :user_id
    boolean :published, default: "false"
    timestamps
    index :user_id
  end
end
```

### 2. Define Models

```crystal
# src/models/user.cr
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter id : Int64?
  getter name : String
  getter email : String
  getter active : Bool
  getter created_at : Time
  getter updated_at : Time

  has_many :posts, Post, foreign_key: :user_id

  validates :name, presence: true, size: 2..50
  validates :email, presence: true
end
```

### 3. Use in Endpoints

```crystal
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user = User.find(params["id"].to_i64)
    UserResponse.new(user)
  end
end

struct UsersEndpoint
  include Azu::Endpoint(EmptyRequest, UsersResponse)

  get "/users"

  def call : UsersResponse
    users = User.where(active: true)
                .order(created_at: :desc)
                .limit(20)
                .all
    UsersResponse.new(users)
  end
end
```

## Supported Databases

| Database | Adapter | Features |
|----------|---------|----------|
| PostgreSQL | `CQL::Adapter::Postgres` | Full support, JSONB, arrays |
| MySQL | `CQL::Adapter::MySQL` | Full support |
| SQLite | `CQL::Adapter::SQLite` | Development and testing |

## Next Steps

- [Schema Definition](schema-definition.md) - Define database tables and indexes
- [Models](models.md) - Create model structs with CRUD operations
- [Relationships](relationships.md) - Set up associations between models
- [Queries](queries.md) - Build type-safe database queries

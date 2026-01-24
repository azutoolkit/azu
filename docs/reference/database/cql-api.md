# CQL API Reference

CQL (Crystal Query Language) is the ORM used with Azu for database operations.

## Schema Definition

### CQL::Schema.define

Create a database schema.

```crystal
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
```

**Parameters:**
- `name : Symbol` - Schema name
- `adapter : CQL::Adapter` - Database adapter
- `uri : String` - Connection string

## Adapters

### Available Adapters

| Adapter | URI Format |
|---------|------------|
| `CQL::Adapter::SQLite` | `sqlite3://./path/to/db.db` |
| `CQL::Adapter::Postgres` | `postgres://user:pass@host:5432/db` |
| `CQL::Adapter::MySql` | `mysql://user:pass@host:3306/db` |

## Table Definition

### table

Define a database table.

```crystal
table :users do
  primary :id, Int64
  column :name, String
  column :email, String
end
```

### primary

Define primary key.

```crystal
primary :id, Int64
primary :uuid, String  # For UUID primary keys
```

### column

Define a column.

```crystal
column :name, String
column :age, Int32?                    # Nullable
column :active, Bool, default: true    # With default
column :created_at, Time, default: -> { Time.utc }
```

**Column Types:**
- `String` - VARCHAR/TEXT
- `Int32`, `Int64` - INTEGER/BIGINT
- `Float32`, `Float64` - REAL/DOUBLE
- `Bool` - BOOLEAN
- `Time` - TIMESTAMP
- `JSON::Any` - JSON

### timestamps

Add created_at and updated_at columns.

```crystal
table :posts do
  primary :id, Int64
  column :title, String
  timestamps  # Adds created_at, updated_at
end
```

### foreign_key

Define a foreign key.

```crystal
table :posts do
  primary :id, Int64
  column :user_id, Int64
  foreign_key :user_id, :users, :id
end
```

### index

Define an index.

```crystal
table :users do
  # ...
  index :email, unique: true
  index [:first_name, :last_name]  # Composite
end
```

## Model Definition

### CQL::Model

Include in class to make it a model.

```crystal
class User
  include CQL::Model(User, Int64)
  db_context MyDB, :users

  property id : Int64?
  property name : String
  property email : String
end
```

**Parameters:**
- First type: Model class
- Second type: Primary key type

### db_context

Set database and table.

```crystal
db_context MyDB, :users
```

## CRUD Operations

### create

Create a new record.

```crystal
user = User.create!(name: "Alice", email: "alice@example.com")
```

### find

Find by primary key.

```crystal
user = User.find(1)      # Raises if not found
user = User.find?(1)     # Returns nil if not found
```

### find_by

Find by attributes.

```crystal
user = User.find_by(email: "alice@example.com")
user = User.find_by?(email: "alice@example.com")
```

### save

Save record (insert or update).

```crystal
user = User.new(name: "Alice", email: "alice@example.com")
user.save!     # Raises on failure
user.save      # Returns Bool
```

### update

Update attributes.

```crystal
user.update!(name: "Alice Smith")
user.update(name: "Alice Smith")
```

### destroy

Delete record.

```crystal
user.destroy!
user.destroy
```

### delete_all

Delete all matching records.

```crystal
User.delete_all
User.where(active: false).delete_all
```

## Query Methods

### all

Get all records.

```crystal
users = User.all
```

### where

Filter records.

```crystal
users = User.where(active: true).all
users = User.where("age > ?", 18).all
```

### order

Sort records.

```crystal
users = User.order(name: :asc).all
users = User.order(created_at: :desc).all
```

### limit / offset

Paginate results.

```crystal
users = User.limit(10).offset(20).all
```

### count

Count records.

```crystal
count = User.count
count = User.where(active: true).count
```

### first / last

Get first or last record.

```crystal
user = User.first
user = User.order(created_at: :desc).first
user = User.last
```

### exists?

Check if records exist.

```crystal
exists = User.where(email: "alice@example.com").exists?
```

## Associations

### belongs_to

```crystal
class Post
  include CQL::Model(Post, Int64)

  property user_id : Int64

  belongs_to :user, User, foreign_key: :user_id
end
```

### has_many

```crystal
class User
  include CQL::Model(User, Int64)

  has_many :posts, Post, foreign_key: :user_id
end
```

### has_one

```crystal
class User
  include CQL::Model(User, Int64)

  has_one :profile, Profile, foreign_key: :user_id
end
```

## Callbacks

### Available Callbacks

- `before_validation`
- `after_validation`
- `before_save`
- `after_save`
- `before_create`
- `after_create`
- `before_update`
- `after_update`
- `before_destroy`
- `after_destroy`

```crystal
class User
  include CQL::Model(User, Int64)

  before_save :normalize_email
  after_create :send_welcome_email

  private def normalize_email
    @email = email.downcase.strip
  end
end
```

## Scopes

Define reusable query scopes.

```crystal
class User
  include CQL::Model(User, Int64)

  scope :active, -> { where(active: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :admins, -> { where(role: "admin") }
end

# Usage
User.active.recent.all
User.admins.count
```

## Transactions

```crystal
MyDB.transaction do
  user = User.create!(name: "Alice")
  Profile.create!(user_id: user.id)
end
```

## Raw Queries

```crystal
MyDB.query("SELECT * FROM users WHERE age > ?", 18)
MyDB.exec("UPDATE users SET active = ? WHERE id = ?", true, 1)
```

## See Also

- [Query Methods Reference](query-methods.md)
- [Validations Reference](validations.md)
- [How to Create Models](../../how-to/database/create-models.md)

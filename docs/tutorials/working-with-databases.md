# Working with Databases

This tutorial teaches you how to connect Azu to a database using CQL, Crystal's type-safe ORM.

## What You'll Build

By the end of this tutorial, you'll have:

- CQL connected to SQLite (or PostgreSQL)
- A type-safe database model with validations and scopes
- CRUD endpoints backed by the database
- A one-to-many relationship between users and posts

## Prerequisites

- Completed [Building a User API](building-a-user-api.md) tutorial (the contracts, responses and endpoints below are
  the same ones, now backed by a database)
- Crystal 1.19.1 or newer
- SQLite (included on most systems), or PostgreSQL if you prefer it

## Step 1: Add CQL Dependencies

CQL is a separate shard; Azu core does not depend on it. Update your `shard.yml` with `cql` and a database driver:

```yaml
name: user_api
version: 0.1.0

dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.52
  cql:
    github: azutoolkit/cql
  # Choose your database driver:
  sqlite3:
    github: crystal-lang/crystal-sqlite3
  # pg:                         # PostgreSQL
  #   github: will/crystal-pg

crystal: ">= 1.19.1"
license: MIT
```

Install dependencies:

```bash
shards install
```

## Step 2: Define the Schema

Create `src/db/schema.cr`. The schema names the tables and columns CQL knows about, and holds the connection:

```crystal
require "cql"
require "sqlite3"

AppDB = CQL::Schema.define(
  :app_database,
  adapter: CQL::Adapter::SQLite,
  uri: ENV.fetch("DATABASE_URL", "sqlite3://./db/development.db")
) do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String, unique: true
    column :age, Int32, null: true
    column :active, Bool, default: true
    timestamps
  end
end
```

Columns are `NOT NULL` unless you pass `null: true`, and `unique: true` creates a `UNIQUE` constraint (and so an index).

For PostgreSQL, `require "pg"` instead of `sqlite3`, use `CQL::Adapter::Postgres` and a `postgres://` URL:

```crystal
require "cql"
require "pg"

AppDB = CQL::Schema.define(
  :app_database,
  adapter: CQL::Adapter::Postgres,
  uri: ENV.fetch("DATABASE_URL", "postgres://localhost:5432/user_api_dev")
) do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String, unique: true
    column :age, Int32, null: true
    column :active, Bool, default: true
    timestamps
  end
end
```

## Step 3: Create the Database

For PostgreSQL create the database first:

```bash
createdb user_api_dev
```

SQLite creates the file on first connection, but the directory must exist:

```bash
mkdir -p db
```

The tables themselves are created by `AppDB.build` (Step 5), which runs `CREATE TABLE IF NOT EXISTS` for every table in
the schema. Once your schema changes over time, use [migrations](../how-to/database/run-migrations.md) instead.

## Step 4: Create the Model

Create `src/models/user.cr`. A model is a class that includes `CQL::ActiveRecord::Model(PrimaryKeyType)`, points at
its table with `db_context`, and declares one property per column:

```crystal
require "cql"
require "sqlite3"

AppDB = CQL::Schema.define(:app_database, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String, unique: true
    column :age, Int32, null: true
    column :active, Bool, default: true
    timestamps
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  property name : String
  property email : String
  property age : Int32?
  property active : Bool = true
  property created_at : Time?
  property updated_at : Time?

  # Validations
  validate :name, presence: true, size: 2..50
  validate :email, presence: true, match: /@/

  # Scopes for common queries
  scope :active, -> { where(active: true) }
  scope :recent, -> { order(created_at: :desc) }

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end

  # Instance methods
  def activate! : Bool
    @active = true
    save!
  end

  def deactivate! : Bool
    @active = false
    save!
  end
end

user = User.new("Ada", "ada@example.com", 36)
user.save!                      # validates, then INSERTs
user.deactivate!
user.activate!
User.active.recent.limit(20).all
```

`save!` validates and raises `CQL::ActiveRecord::Validations::ValidationError` for an invalid record. `User.create!(...)`
writes straight to the database without validations or callbacks, so the tutorial builds records with `new` and
`save!`.

## Step 5: The Complete Application

Replace `src/user_api.cr` with the application below. It reuses the contracts and responses from the User API tutorial
and swaps the in-memory store for CQL. Read it in the order it is written: schema, model, contracts, responses, the
five endpoints, then the server.

```crystal
require "azu"
require "cql"
require "sqlite3"

# --- Database ---------------------------------------------------------------

AppDB = CQL::Schema.define(
  :app_database,
  adapter: CQL::Adapter::SQLite,
  uri: ENV.fetch("DATABASE_URL", "sqlite3://./db/development.db")
) do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String, unique: true
    column :age, Int32, null: true
    column :active, Bool, default: true
    timestamps
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  property name : String
  property email : String
  property age : Int32?
  property active : Bool = true
  property created_at : Time?
  property updated_at : Time?

  validate :name, presence: true, size: 2..50
  validate :email, presence: true, match: /@/

  scope :active, -> { where(active: true) }
  scope :recent, -> { order(created_at: :desc) }

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

# Turns the model's validation failures into Azu's 422 response.
def save_user!(user : User) : User
  user.save!
  user
rescue ex : CQL::ActiveRecord::Validations::ValidationError
  fields = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
  user.errors.each { |error| fields[error.field.to_s] << error.message }
  raise Azu::Response::ValidationError.new(fields.to_h)
end

# --- Contracts and responses ------------------------------------------------

struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  def initialize(@name = "", @email = "", @age = nil)
  end

  validate name, presence: true, size: 2..50
  validate email, presence: true, match: /@/
end

struct UpdateUserRequest
  include Azu::Request

  getter name : String?
  getter email : String?
  getter age : Int32?

  def initialize(@name = nil, @email = nil, @age = nil)
  end
end

struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id:         @user.id,
      name:       @user.name,
      email:      @user.email,
      age:        @user.age,
      active:     @user.active,
      created_at: @user.created_at,
    }.to_json
  end
end

struct UsersListResponse
  include Azu::Response

  def initialize(@users : Array(User))
  end

  def render
    {
      users: @users.map { |user| {id: user.id, name: user.name, email: user.email} },
      total: @users.size,
    }.to_json
  end
end

# --- Endpoints ---------------------------------------------------------------

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # The contract has already been validated; check what only the database knows
    if User.exists?(email: create_user_request.email)
      raise Azu::Response::ValidationError.new("email", "is already taken")
    end

    user = save_user!(User.new(create_user_request.name, create_user_request.email, create_user_request.age))

    status 201
    content_type "application/json"
    UserResponse.new(user)
  end
end

struct ListUsersEndpoint
  include Azu::Endpoint(Azu::Request, UsersListResponse)

  get "/users"

  def call : UsersListResponse
    # Scopes chain like any other query
    users = User.active.recent.limit(100).all
    content_type "application/json"
    UsersListResponse.new(users)
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64

    if user = User.find?(user_id)
      content_type "application/json"
      UserResponse.new(user)
    else
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end
  end
end

struct UpdateUserEndpoint
  include Azu::Endpoint(UpdateUserRequest, UserResponse)

  put "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64

    unless user = User.find?(user_id)
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end

    if email = update_user_request.email
      if (existing = User.find_by(email: email)) && existing.id != user_id
        raise Azu::Response::ValidationError.new("email", "is already taken")
      end
      user.email = email
    end

    update_user_request.name.try { |name| user.name = name }
    update_user_request.age.try { |age| user.age = age }

    save_user!(user)
    content_type "application/json"
    UserResponse.new(user)
  end
end

struct DeleteUserEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  delete "/users/:id"

  def call : Azu::Response::Empty
    user_id = params["id"].to_i64

    unless user = User.find?(user_id)
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end

    user.delete!
    status 204
    Azu::Response::Empty.new
  end
end

# --- Server --------------------------------------------------------------------

module UserAPI
  include Azu

  configure do |config|
    config.port = ENV.fetch("PORT", "4000").to_i
    config.host = ENV.fetch("HOST", "0.0.0.0")
  end
end

# Create the tables if they do not exist yet
AppDB.build

UserAPI.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  Azu::Handler::CORS.new,
] of HTTP::Handler
```

What changed from the in-memory version:

- **Create** checks for a duplicate e-mail with `User.exists?`, builds the record with `User.new` and saves it with
  `save!`. A model that fails its validations becomes the same `422` response a broken contract produces.
- **List** uses the `active` and `recent` scopes and always limits the result.
- **Show** uses `find?`, which returns `nil` when there is no row, and answers `404` through `Azu::Response::NotFound`.
- **Update** assigns only the fields the client sent and saves; `update!(name: ...)` would skip validations.
- **Delete** calls `delete!`, which returns `false` if the row was already gone.
- Endpoints register themselves with the router when their struct is defined, so they are not listed in `start`.

Run it:

```bash
crystal run src/user_api.cr
curl -X POST localhost:4000/users -H 'Content-Type: application/json' \
  -d '{"name":"Ada","email":"ada@example.com","age":36}'
curl localhost:4000/users
```

## Step 6: Adding Relationships

Add a `posts` table to the schema and a model for it. `belongs_to` and `has_many` name the foreign key explicitly, and the
foreign key must be a property of the model that holds it:

```crystal
require "cql"
require "sqlite3"

AppDB = CQL::Schema.define(:app_database, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String, unique: true
    column :age, Int32, null: true
    column :active, Bool, default: true
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
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :posts

  property user_id : Int64
  property title : String
  property content : String
  property published : Bool = false
  property created_at : Time?
  property updated_at : Time?

  belongs_to :user, User, :user_id

  validate :title, presence: true, size: 5..200
  validate :content, presence: true

  scope :published, -> { where(published: true) }
  scope :drafts, -> { where(published: false) }
  scope :by_user, ->(id : Int64) { where(user_id: id) }

  def initialize(@user_id : Int64, @title : String, @content : String)
  end

  def publish! : Bool
    @published = true
    save!
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  property name : String
  property email : String
  property age : Int32?
  property active : Bool = true
  property created_at : Time?
  property updated_at : Time?

  has_many :posts, Post, foreign_key: :user_id

  scope :active, -> { where(active: true) }
  scope :recent, -> { order(created_at: :desc) }

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

Post.find!(1_i64).publish!
User.find!(1_i64).posts.to_a
```

The `on_delete: :cascade` on the foreign key makes the database remove a user's posts with the user. (CQL's
`dependent:` option on `has_many` is not applied by `delete!`, so let the database do it; SQLite enforces foreign keys
only when `PRAGMA foreign_keys = ON`.)

## Step 7: Query Examples

```crystal
require "cql"
require "sqlite3"

AppDB = CQL::Schema.define(:app_database, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String, unique: true
    column :age, Int32, null: true
    column :active, Bool, default: true
    timestamps
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
    column :content, String
    column :published, Bool, default: false
    timestamps
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :posts

  property user_id : Int64
  property title : String
  property content : String
  property published : Bool = false
  property created_at : Time?

  belongs_to :user, User, :user_id

  scope :published, -> { where(published: true) }

  def initialize(@user_id : Int64, @title : String, @content : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  property name : String
  property email : String
  property age : Int32?
  property active : Bool = true
  property created_at : Time?

  has_many :posts, Post, foreign_key: :user_id

  scope :active, -> { where(active: true) }
  scope :recent, -> { order(created_at: :desc) }

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

# Find by ID
user = User.find(1_i64)        # User? (nil when missing)
user = User.find!(1_i64)       # raises DB::NoResultsError when missing

# Find by attributes
user = User.find_by(email: "alice@example.com")

# Queries with conditions
active_users = User.where(active: true).all
recent_users = User.order(created_at: :desc).limit(10).all
adults = User.where("age >= ?", 18).all

# Using scopes
User.active.recent.limit(20).all

# Relationships
user = User.find!(1_i64)
user_posts = user.posts.to_a
published_posts = user.posts.where(published: true).all(Post)
author = Post.find!(1_i64).user

# Avoid N+1: load all users' posts with one extra query
User.preload(:posts).all.each { |u| puts "#{u.name}: #{u.posts.size}" }

# Create with a relationship
post = Post.new(user.id!, "My First Post", "Hello, world!")
post.save!

# Count records
User.count
User.where(active: true).count
Post.published.count
```

## Environment Configuration

Create a `.env` file (or export the variables) for development:

```bash
DATABASE_URL=sqlite3://./db/development.db
PORT=4000
```

For production with PostgreSQL:

```bash
DATABASE_URL=postgres://user:password@db.example.com:5432/user_api_prod
PORT=8080
```

`DATABASE_URL` is read by the schema's `uri:` argument shown in Step 2. To pick the adapter from the URL automatically,
configure the connection pool and see every query in the dev dashboard, `require "azu/cql"` and define the schema with
`Azu::CQL.schema`; see [Database dashboard](../reference/database-dashboard.md).

## Key Concepts Learned

### Schema Definition

```crystal
require "cql"
require "sqlite3"

DemoDB = CQL::Schema.define(:demo, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/demo.db") do
  table :items do
    primary :id, Int64
    column :label, String
    column :note, String, null: true
    timestamps
  end
end
```

### Model Definition

```crystal
require "cql"
require "sqlite3"

DemoDB = CQL::Schema.define(:demo, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/demo.db") do
  table :items do
    primary :id, Int64
    column :label, String
  end
end

class Item
  include CQL::ActiveRecord::Model(Int64)
  db_context DemoDB, :items

  property label : String

  validate :label, presence: true
  scope :labelled, ->(text : String) { where(label: text) }

  def initialize(@label : String)
  end
end
```

### CRUD Operations

```crystal
require "cql"
require "sqlite3"

DemoDB = CQL::Schema.define(:demo, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/demo.db") do
  table :items do
    primary :id, Int64
    column :label, String
  end
end

class Item
  include CQL::ActiveRecord::Model(Int64)
  db_context DemoDB, :items

  property label : String

  def initialize(@label : String)
  end
end

item = Item.new("first")
item.save!                      # Create (validates)
Item.find?(1_i64)               # Read
item.label = "renamed"
item.save!                      # Update
item.delete!                    # Delete
```

## Next Steps

Your API now persists data to a database. Continue learning with:

- [Building Live Components](building-live-components.md) - Create real-time UI
- [Testing Your App](testing-your-app.md) - Test database operations
- [Deploying to Production](deploying-to-production.md) - Production database setup
- [CQL API Reference](../reference/database/cql-api.md) - Everything CQL offers

---

**Database integration complete!** Your application now stores data persistently with type-safe queries.

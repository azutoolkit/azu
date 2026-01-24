# Working with Databases

This tutorial teaches you how to connect Azu to a database using CQL, Crystal's type-safe ORM.

## What You'll Build

By the end of this tutorial, you'll have:

- CQL connected to PostgreSQL (or SQLite for development)
- Type-safe database models
- CRUD operations with proper validation
- Integration with Azu endpoints

## Prerequisites

- Completed [Building a User API](building-a-user-api.md) tutorial
- PostgreSQL installed (or SQLite for development)

## Step 1: Add CQL Dependencies

Update your `shard.yml`:

```yaml
name: user_api
version: 0.1.0

dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.28
  cql:
    github: azutoolkit/cql
    version: ~> 0.1.0
  # Choose your database driver:
  pg:                           # PostgreSQL
    github: will/crystal-pg
  # OR
  # sqlite3:                    # SQLite (development)
  #   github: crystal-lang/crystal-sqlite3

crystal: >= 0.35.0
license: MIT
```

Install dependencies:

```bash
shards install
```

## Step 2: Define the Schema

Create `src/config/database.cr`:

```crystal
require "cql"

AppDB = CQL::Schema.define(
  :app_database,
  adapter: CQL::Adapter::Postgres,
  uri: ENV.fetch("DATABASE_URL", "postgres://localhost:5432/user_api_dev")
) do
  table :users do
    primary :id, Int64
    text :name
    text :email
    integer :age, null: true
    boolean :active, default: "true"
    timestamps

    index :email, unique: true
  end
end
```

For SQLite development:

```crystal
AppDB = CQL::Schema.define(
  :app_database,
  adapter: CQL::Adapter::SQLite,
  uri: "sqlite3://./db/development.db"
) do
  # Same table definitions...
end
```

## Step 3: Create the Database

For PostgreSQL:

```bash
createdb user_api_dev
```

For SQLite:

```bash
mkdir -p db
touch db/development.db
```

## Step 4: Create the Model

Replace `src/models/user.cr` with a CQL-backed model:

```crystal
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter id : Int64?
  getter name : String
  getter email : String
  getter age : Int32?
  getter active : Bool
  getter created_at : Time
  getter updated_at : Time

  # Validations
  validates :name, presence: true, size: 2..50
  validates :email, presence: true

  # Scopes for common queries
  scope :active, -> { where(active: true) }
  scope :recent, -> { order(created_at: :desc) }

  # Instance methods
  def activate!
    @active = true
    save!
  end

  def deactivate!
    @active = false
    save!
  end
end
```

## Step 5: Update Endpoints

Update `src/endpoints/create_user_endpoint.cr`:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Validate request
    unless create_user_request.valid?
      raise Azu::Response::ValidationError.new(
        create_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
      )
    end

    # Check for duplicate email
    if User.find_by(email: create_user_request.email)
      raise Azu::Response::ValidationError.new(
        {"email" => ["Email is already taken"]}
      )
    end

    # Create user in database
    user = User.create!(
      name: create_user_request.name,
      email: create_user_request.email,
      age: create_user_request.age
    )

    status 201
    UserResponse.new(user)
  rescue CQL::RecordInvalid => e
    raise Azu::Response::ValidationError.new(e.errors)
  end
end
```

Update `src/endpoints/list_users_endpoint.cr`:

```crystal
struct ListUsersEndpoint
  include Azu::Endpoint(EmptyRequest, UsersListResponse)

  get "/users"

  def call : UsersListResponse
    # Use scopes for filtering
    users = User.active.recent.limit(100).all
    UsersListResponse.new(users)
  end
end
```

Update `src/endpoints/show_user_endpoint.cr`:

```crystal
struct ShowUserEndpoint
  include Azu::Endpoint(EmptyRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64

    if user = User.find?(user_id)
      UserResponse.new(user)
    else
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end
  end
end
```

Update `src/endpoints/update_user_endpoint.cr`:

```crystal
struct UpdateUserEndpoint
  include Azu::Endpoint(UpdateUserRequest, UserResponse)

  put "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64

    unless user = User.find?(user_id)
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end

    unless update_user_request.valid?
      raise Azu::Response::ValidationError.new(
        update_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
      )
    end

    # Check duplicate email
    if email = update_user_request.email
      if existing = User.find_by(email: email)
        unless existing.id == user_id
          raise Azu::Response::ValidationError.new(
            {"email" => ["Email is already taken"]}
          )
        end
      end
    end

    # Update the user
    user.update!(
      name: update_user_request.name,
      email: update_user_request.email,
      age: update_user_request.age
    )

    UserResponse.new(user)
  rescue CQL::RecordInvalid => e
    raise Azu::Response::ValidationError.new(e.errors)
  end
end
```

Update `src/endpoints/delete_user_endpoint.cr`:

```crystal
struct DeleteUserEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Empty)

  delete "/users/:id"

  def call : Azu::Response::Empty
    user_id = params["id"].to_i64

    unless user = User.find?(user_id)
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end

    user.destroy!
    status 204
    Azu::Response::Empty.new
  end
end
```

## Step 6: Update Main Application

Update `src/user_api.cr`:

```crystal
require "azu"

# Load database configuration first
require "./config/database"

# Load application files
require "./models/*"
require "./requests/*"
require "./responses/*"
require "./endpoints/*"

module UserAPI
  include Azu

  configure do
    port = ENV.fetch("PORT", "4000").to_i
    host = ENV.fetch("HOST", "0.0.0.0")
  end
end

# Create tables if they don't exist
AppDB.create_tables

# Start the application
UserAPI.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  Azu::Handler::CORS.new,
  ListUsersEndpoint.new,
  ShowUserEndpoint.new,
  CreateUserEndpoint.new,
  UpdateUserEndpoint.new,
  DeleteUserEndpoint.new,
]
```

## Step 7: Adding Relationships

Add a posts table to your schema:

```crystal
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

Create `src/models/post.cr`:

```crystal
struct Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :posts

  getter id : Int64?
  getter title : String
  getter content : String
  getter user_id : Int64
  getter published : Bool
  getter created_at : Time
  getter updated_at : Time

  belongs_to :user, User, foreign_key: :user_id

  validates :title, presence: true, size: 5..200
  validates :content, presence: true
  validates :user_id, presence: true

  scope :published, -> { where(published: true) }
  scope :drafts, -> { where(published: false) }
  scope :by_user, ->(id : Int64) { where(user_id: id) }

  def publish!
    @published = true
    save!
  end
end
```

Update the User model with the relationship:

```crystal
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  # ... existing fields ...

  has_many :posts, Post, foreign_key: :user_id
end
```

## Step 8: Query Examples

```crystal
# Find by ID
user = User.find(1)           # Raises if not found
user = User.find?(1)          # Returns nil if not found

# Find by attributes
user = User.find_by(email: "alice@example.com")

# Queries with conditions
active_users = User.where(active: true).all
recent_users = User.order(created_at: :desc).limit(10).all

# Using scopes
User.active.recent.limit(20).all

# Relationships
user = User.find(1)
user_posts = user.posts.all
published_posts = user.posts.published.all

# Create with relationship
post = Post.create!(
  title: "My First Post",
  content: "Hello, world!",
  user_id: user.id
)

# Count records
User.count
User.where(active: true).count
```

## Environment Configuration

Create a `.env` file for development:

```bash
DATABASE_URL=postgres://localhost:5432/user_api_dev
PORT=4000
```

For production:

```bash
DATABASE_URL=postgres://user:password@db.example.com:5432/user_api_prod
PORT=8080
```

## Key Concepts Learned

### Schema Definition

```crystal
CQL::Schema.define(:name, adapter: Adapter, uri: "...") do
  table :name do
    primary :id, Int64
    text :field
    timestamps
    index :field, unique: true
  end
end
```

### Model Definition

```crystal
struct Model
  include CQL::ActiveRecord::Model(Int64)
  db_context Schema, :table

  getter field : Type
  validates :field, presence: true
  scope :name, -> { where(...) }
  has_many :relation, OtherModel
end
```

### CRUD Operations

```crystal
Model.create!(attrs)      # Create
Model.find?(id)           # Read
model.update!(attrs)      # Update
model.destroy!            # Delete
```

## Next Steps

Your API now persists data to a database. Continue learning with:

- [Building Live Components](building-live-components.md) - Create real-time UI
- [Testing Your App](testing-your-app.md) - Test database operations
- [Deploying to Production](deploying-to-production.md) - Production database setup

---

**Database integration complete!** Your application now stores data persistently with type-safe queries.

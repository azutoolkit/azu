# Models

CQL models are Crystal structs that map to database tables, providing type-safe CRUD operations.

## Defining a Model

```crystal
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter id : Int64?
  getter name : String
  getter email : String
  getter active : Bool
  getter created_at : Time
  getter updated_at : Time
end
```

Key components:
- `include CQL::ActiveRecord::Model(Int64)` - Include model behavior with primary key type
- `db_context AppDB, :users` - Bind model to schema and table
- `getter` properties - Map to database columns

## Primary Key Types

```crystal
# Int64 (default, auto-increment)
include CQL::ActiveRecord::Model(Int64)

# Int32
include CQL::ActiveRecord::Model(Int32)

# UUID
include CQL::ActiveRecord::Model(UUID)
```

## CRUD Operations

### Create

```crystal
# Create and save
user = User.create!(name: "Alice", email: "alice@example.com")

# Build then save
user = User.new(name: "Bob", email: "bob@example.com")
user.save!
```

### Read

```crystal
# Find by ID
user = User.find(1)          # Raises if not found
user = User.find?(1)         # Returns nil if not found

# Find by attributes
user = User.find_by(email: "alice@example.com")

# Get all records
users = User.all

# Get first/last
first_user = User.first
last_user = User.last
```

### Update

```crystal
user = User.find(1)
user.name = "Updated Name"
user.save!

# Update specific attributes
user.update!(name: "New Name", email: "new@example.com")
```

### Delete

```crystal
user = User.find(1)
user.destroy!

# Delete by ID
User.delete(1)
```

## Scopes

Define reusable query filters:

```crystal
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter id : Int64?
  getter name : String
  getter email : String
  getter active : Bool
  getter created_at : Time

  # Define scopes
  scope :active, -> { where(active: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :admins, -> { where(admin: true) }
end

# Use scopes
active_users = User.active.all
recent_admins = User.admins.recent.limit(10).all
```

## Callbacks

Execute code at specific points in the model lifecycle:

```crystal
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter id : Int64?
  getter name : String
  getter email : String
  getter password_digest : String
  getter created_at : Time
  getter updated_at : Time

  # Lifecycle callbacks
  before_save :normalize_email
  before_create :set_defaults
  after_create :send_welcome_email
  after_save :clear_cache

  private def normalize_email
    @email = @email.downcase.strip
  end

  private def set_defaults
    @active = true if @active.nil?
  end

  private def send_welcome_email
    # EmailService.welcome(self)
  end

  private def clear_cache
    # Azu.cache.delete("user:#{id}")
  end
end
```

Available callbacks:
- `before_save`, `after_save`
- `before_create`, `after_create`
- `before_update`, `after_update`
- `before_destroy`, `after_destroy`

## Using with Azu Endpoints

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Validate request
    raise Azu::Response::ValidationError.new(request.errors) unless request.valid?

    # Create user
    user = User.create!(
      name: request.name,
      email: request.email
    )

    UserResponse.new(user)
  rescue CQL::RecordInvalid => e
    raise Azu::Response::ValidationError.new(e.errors)
  end
end

struct GetUserEndpoint
  include Azu::Endpoint(EmptyRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user = User.find?(params["id"].to_i64)
    raise Azu::Response::NotFound.new("User not found") unless user
    UserResponse.new(user)
  end
end
```

## Model with All Features

```crystal
struct Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :posts

  getter id : Int64?
  getter title : String
  getter content : String
  getter slug : String
  getter user_id : Int64
  getter published : Bool
  getter published_at : Time?
  getter created_at : Time
  getter updated_at : Time

  # Relationships
  belongs_to :user, User, foreign_key: :user_id

  # Validations
  validates :title, presence: true, size: 5..200
  validates :content, presence: true
  validates :user_id, presence: true

  # Scopes
  scope :published, -> { where(published: true) }
  scope :drafts, -> { where(published: false) }
  scope :by_user, ->(user_id : Int64) { where(user_id: user_id) }
  scope :recent, -> { order(created_at: :desc) }

  # Callbacks
  before_save :generate_slug

  private def generate_slug
    @slug = title.downcase.gsub(/[^a-z0-9]+/, "-").strip("-")
  end

  def publish!
    @published = true
    @published_at = Time.utc
    save!
  end
end
```

## Next Steps

- [Relationships](relationships.md) - Define associations between models
- [Validations](validations.md) - Validate model data
- [Queries](queries.md) - Build complex database queries

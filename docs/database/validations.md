# Validations

CQL provides model-level validations that run before saving records to the database.

## Model vs Request Validations

Azu applications have two validation layers:

| Layer | Purpose | When to Use |
|-------|---------|-------------|
| **Request Validations** (`Azu::Request`) | Validate incoming HTTP data | Input sanitization, format checks |
| **Model Validations** (`CQL::ActiveRecord`) | Validate business rules | Uniqueness, relationships, complex rules |

Both layers work together for defense in depth.

## Basic Validations

```crystal
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter id : Int64?
  getter name : String
  getter email : String
  getter age : Int32?

  # Required field
  validates :name, presence: true

  # Length constraints
  validates :name, size: 2..50

  # Format validation
  validates :email, match: /\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i

  # Numeric validation
  validates :age, gt: 0, lt: 150
end
```

## Available Validators

### Presence

```crystal
validates :name, presence: true
validates :email, presence: true
```

### Size/Length

```crystal
# Range
validates :username, size: 3..20

# Minimum
validates :password, size: 8..

# Maximum
validates :bio, size: ..500
```

### Format

```crystal
# Regex pattern
validates :email, match: /\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i
validates :phone, match: /\A\+?[0-9]{10,15}\z/
validates :slug, match: /\A[a-z0-9\-]+\z/
```

### Numeric

```crystal
# Greater than
validates :age, gt: 0

# Less than
validates :age, lt: 150

# Range
validates :rating, gte: 1, lte: 5

# Equal to
validates :quantity, gte: 0
```

### Inclusion

```crystal
validates :status, in: ["pending", "active", "suspended"]
validates :role, in: ["user", "admin", "moderator"]
```

### Exclusion

```crystal
validates :username, not_in: ["admin", "root", "system"]
```

### Confirmation

```crystal
getter password : String
getter password_confirmation : String

validates :password_confirmation, confirmation: :password
```

## Combining Validators

```crystal
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter name : String
  getter email : String
  getter username : String
  getter password_digest : String
  getter role : String

  # Multiple validations on one field
  validates :name, presence: true, size: 2..100

  validates :email, presence: true, match: /\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i

  validates :username,
    presence: true,
    size: 3..20,
    match: /\A[a-z0-9_]+\z/,
    not_in: ["admin", "root"]

  validates :role, presence: true, in: ["user", "admin"]
end
```

## Custom Validations

```crystal
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter email : String
  getter username : String

  # Built-in validations
  validates :email, presence: true

  # Custom validation method
  validate :email_domain_allowed

  private def email_domain_allowed
    blocked = ["tempmail.com", "throwaway.com"]
    domain = email.split("@").last

    if blocked.includes?(domain)
      errors.add(:email, "domain not allowed")
    end
  end
end
```

## Validation Errors

```crystal
user = User.new(name: "", email: "invalid")

unless user.valid?
  user.errors.each do |error|
    puts "#{error.field}: #{error.message}"
  end
end

# Check specific field
if user.errors.on?(:email)
  puts "Email is invalid"
end

# Get all error messages
messages = user.errors.full_messages
# => ["Name can't be blank", "Email is invalid"]
```

## Saving with Validations

```crystal
# save! raises on validation failure
begin
  user.save!
rescue CQL::RecordInvalid => e
  puts e.errors.full_messages
end

# save returns false on failure
if user.save
  puts "User saved"
else
  puts user.errors.full_messages
end

# Skip validations (use with caution)
user.save!(validate: false)
```

## Integration with Azu Endpoints

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Request-level validation (format, sanitization)
    unless request.valid?
      raise Azu::Response::ValidationError.new(format_errors(request.errors))
    end

    # Create user (model validation runs on save)
    user = User.new(
      name: request.name,
      email: request.email,
      username: request.username
    )

    user.save!
    UserResponse.new(user)

  rescue CQL::RecordInvalid => e
    # Model-level validation failed (uniqueness, business rules)
    raise Azu::Response::ValidationError.new(format_errors(e.errors))
  end

  private def format_errors(errors)
    errors.group_by(&.field).transform_values(&.map(&.message))
  end
end

struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter username : String

  # Request-level validations
  validate name, presence: true, length: { min: 2 }
  validate email, presence: true, format: /@/
  validate username, presence: true, length: { min: 3, max: 20 }
end
```

## Next Steps

- [Models](models.md) - Full model definition with validations
- [Queries](queries.md) - Query validated data

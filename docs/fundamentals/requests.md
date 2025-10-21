# Request Contracts

Request contracts are the foundation of type-safe input validation in Azu. They define exactly what data your endpoints expect and automatically validate incoming requests.

## What are Request Contracts?

A request contract is a type-safe object that:

- **Defines Input Structure**: Specifies what fields are expected
- **Validates Data**: Automatically validates incoming data
- **Provides Type Safety**: Ensures compile-time type safety
- **Generates Errors**: Produces detailed validation error messages

## Basic Request Contract

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  def initialize(@name = "", @email = "", @age = nil)
  end

  # Validation rules
  validate name, presence: true, length: {min: 2, max: 50}
  validate email, presence: true, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
  validate age, numericality: {greater_than: 0, less_than: 150}, allow_nil: true
end
```

### Key Components

1. **Module Include**: `include Azu::Request`
2. **Property Declarations**: Define expected fields with types
3. **Initializer**: Set default values for optional fields
4. **Validation Rules**: Define validation constraints

## Field Types

Request contracts support all Crystal types:

### Basic Types

```crystal
struct BasicRequest
  include Azu::Request

  getter string_field : String
  getter int_field : Int32
  getter float_field : Float64
  getter bool_field : Bool
  getter time_field : Time
  getter json_field : JSON::Any

  def initialize(@string_field = "", @int_field = 0, @float_field = 0.0,
                 @bool_field = false, @time_field = Time.utc, @json_field = JSON::Any.new(nil))
  end
end
```

### Optional Fields

```crystal
struct OptionalRequest
  include Azu::Request

  getter required_field : String
  getter optional_field : String?
  getter nullable_int : Int32?

  def initialize(@required_field = "", @optional_field = nil, @nullable_int = nil)
  end
end
```

### Array Fields

```crystal
struct ArrayRequest
  include Azu::Request

  getter tags : Array(String)
  getter numbers : Array(Int32)
  getter optional_array : Array(String)?

  def initialize(@tags = [] of String, @numbers = [] of Int32, @optional_array = nil)
  end
end
```

### Hash Fields

```crystal
struct HashRequest
  include Azu::Request

  getter metadata : Hash(String, String)
  getter config : Hash(String, JSON::Any)?

  def initialize(@metadata = {} of String => String, @config = nil)
  end
end
```

## Validation Rules

Azu provides comprehensive validation rules:

### Presence Validation

```crystal
struct PresenceRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  # Required fields
  validate name, presence: true
  validate email, presence: true

  # Optional fields (no presence validation)
  # Fields without presence validation are optional
end
```

### Length Validation

```crystal
struct LengthRequest
  include Azu::Request

  getter name : String
  getter description : String

  def initialize(@name = "", @description = "")
  end

  # Exact length
  validate name, length: {exactly: 10}

  # Minimum length
  validate name, length: {min: 2}

  # Maximum length
  validate name, length: {max: 50}

  # Range
  validate description, length: {min: 10, max: 500}
end
```

### Format Validation

```crystal
struct FormatRequest
  include Azu::Request

  getter email : String
  getter phone : String
  getter url : String

  def initialize(@email = "", @phone = "", @url = "")
  end

  # Email format
  validate email, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i

  # Phone format
  validate phone, format: /\A\+?[\d\s\-\(\)]+\z/

  # URL format
  validate url, format: /\Ahttps?:\/\/.+\z/
end
```

### Numerical Validation

```crystal
struct NumericalRequest
  include Azu::Request

  getter age : Int32
  getter price : Float64
  getter score : Int32?

  def initialize(@age = 0, @price = 0.0, @score = nil)
  end

  # Greater than
  validate age, numericality: {greater_than: 0}

  # Less than
  validate age, numericality: {less_than: 150}

  # Range
  validate age, numericality: {greater_than: 0, less_than: 150}

  # Allow nil
  validate score, numericality: {greater_than: 0, less_than: 100}, allow_nil: true
end
```

### Inclusion Validation

```crystal
struct InclusionRequest
  include Azu::Request

  getter status : String
  getter priority : String?

  def initialize(@status = "", @priority = nil)
  end

  # Must be one of the specified values
  validate status, inclusion: {in: ["active", "inactive", "pending"]}

  # Optional inclusion
  validate priority, inclusion: {in: ["low", "medium", "high"]}, allow_nil: true
end
```

### Exclusion Validation

```crystal
struct ExclusionRequest
  include Azu::Request

  getter username : String
  getter email : String

  def initialize(@username = "", @email = "")
  end

  # Must not be one of the specified values
  validate username, exclusion: {in: ["admin", "root", "system"]}
  validate email, exclusion: {in: ["admin@example.com", "root@example.com"]}
end
```

### Custom Validation

```crystal
struct CustomRequest
  include Azu::Request

  getter password : String
  getter confirm_password : String

  def initialize(@password = "", @confirm_password = "")
  end

  # Custom validation method
  validate password, custom: :validate_password_strength
  validate confirm_password, custom: :validate_password_match

  private def validate_password_strength
    return if @password.empty?

    if @password.size < 8
      errors.add("password", "must be at least 8 characters long")
    end

    unless @password.match(/\d/)
      errors.add("password", "must contain at least one number")
    end

    unless @password.match(/[A-Z]/)
      errors.add("password", "must contain at least one uppercase letter")
    end
  end

  private def validate_password_match
    return if @confirm_password.empty?

    if @password != @confirm_password
      errors.add("confirm_password", "must match password")
    end
  end
end
```

## Error Messages

Customize validation error messages:

```crystal
struct CustomMessagesRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32

  def initialize(@name = "", @email = "", @age = 0)
  end

  # Custom error messages
  validate name, presence: true, message: "Name is required"
  validate name, length: {min: 2, max: 50}, message: "Name must be between 2 and 50 characters"

  validate email, presence: true, message: "Email address is required"
  validate email, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i,
    message: "Please enter a valid email address"

  validate age, numericality: {greater_than: 0, less_than: 150},
    message: "Age must be between 1 and 149"
end
```

## Nested Objects

Handle complex nested data structures:

```crystal
struct Address
  include Azu::Request

  getter street : String
  getter city : String
  getter state : String
  getter zip_code : String

  def initialize(@street = "", @city = "", @state = "", @zip_code = "")
  end

  validate street, presence: true
  validate city, presence: true
  validate state, presence: true
  validate zip_code, format: /\A\d{5}(-\d{4})?\z/
end

struct UserWithAddressRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter address : Address

  def initialize(@name = "", @email = "", @address = Address.new)
  end

  validate name, presence: true
  validate email, presence: true, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
  validate address, presence: true
end
```

## Array Validation

Validate arrays of objects:

```crystal
struct Tag
  include Azu::Request

  getter name : String
  getter color : String

  def initialize(@name = "", @color = "")
  end

  validate name, presence: true, length: {min: 1, max: 20}
  validate color, inclusion: {in: ["red", "blue", "green", "yellow", "purple"]}
end

struct PostWithTagsRequest
  include Azu::Request

  getter title : String
  getter content : String
  getter tags : Array(Tag)

  def initialize(@title = "", @content = "", @tags = [] of Tag)
  end

  validate title, presence: true, length: {min: 5, max: 100}
  validate content, presence: true, length: {min: 10}
  validate tags, length: {min: 1, max: 5}, message: "Must have between 1 and 5 tags"
end
```

## Conditional Validation

Apply validation rules conditionally:

```crystal
struct ConditionalRequest
  include Azu::Request

  getter user_type : String
  getter company_name : String?
  getter personal_email : String?

  def initialize(@user_type = "", @company_name = nil, @personal_email = nil)
  end

  validate user_type, inclusion: {in: ["individual", "business"]}

  # Company name required for business users
  validate company_name, presence: true, if: :business_user?

  # Personal email required for individual users
  validate personal_email, presence: true, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i, if: :individual_user?

  private def business_user?
    @user_type == "business"
  end

  private def individual_user?
    @user_type == "individual"
  end
end
```

## Data Sources

Request contracts can parse data from different sources:

### JSON Data

```crystal
# From JSON string
request = CreateUserRequest.from_json(json_string)

# From JSON object
request = CreateUserRequest.from_json(json_object)
```

### Form Data

```crystal
# From URL-encoded form data
request = CreateUserRequest.from_www_form(form_string)

# From form parameters
request = CreateUserRequest.from_www_form(params)
```

### Direct Initialization

```crystal
# Direct initialization
request = CreateUserRequest.new(
  name: "Alice",
  email: "alice@example.com",
  age: 30
)
```

## Validation Methods

Check validation status and access errors:

```crystal
request = CreateUserRequest.new(name: "", email: "invalid")

# Check if valid
if request.valid?
  # Process valid request
  process_user(request)
else
  # Handle validation errors
  handle_errors(request.errors)
end

# Force validation (raises exception if invalid)
request.validate!

# Get all errors
errors = request.errors

# Get errors for specific field
name_errors = request.errors.select { |e| e.field == "name" }

# Get error messages
error_messages = request.errors.map(&.message)
```

## Error Handling

Handle validation errors in your endpoints:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Check validation
    unless create_user_request.valid?
      raise Azu::Response::ValidationError.new(
        create_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
      )
    end

    # Process valid request
    user = create_user(create_user_request)
    UserResponse.new(user)
  end
end
```

## Testing Request Contracts

Test your request contracts:

```crystal
require "spec"

describe CreateUserRequest do
  it "validates required fields" do
    request = CreateUserRequest.new(name: "", email: "")

    request.valid?.should be_false
    request.errors.any? { |e| e.field == "name" }.should be_true
    request.errors.any? { |e| e.field == "email" }.should be_true
  end

  it "validates email format" do
    request = CreateUserRequest.new(name: "Alice", email: "invalid-email")

    request.valid?.should be_false
    request.errors.any? { |e| e.field == "email" }.should be_true
  end

  it "accepts valid data" do
    request = CreateUserRequest.new(
      name: "Alice",
      email: "alice@example.com",
      age: 30
    )

    request.valid?.should be_true
  end
end
```

## Best Practices

### 1. Use Descriptive Names

```crystal
# Good: Descriptive and specific
struct CreateUserRequest
struct UpdateUserRequest
struct DeleteUserRequest

# Avoid: Generic names
struct UserRequest
struct DataRequest
```

### 2. Group Related Fields

```crystal
struct UserRequest
  include Azu::Request

  # Personal information
  getter first_name : String
  getter last_name : String
  getter email : String

  # Contact information
  getter phone : String?
  getter address : String?

  # Preferences
  getter newsletter : Bool
  getter notifications : Bool
end
```

### 3. Use Appropriate Types

```crystal
# Good: Specific types
getter age : Int32
getter price : Float64
getter active : Bool

# Avoid: Generic types
getter age : String  # Should be Int32
getter price : String  # Should be Float64
```

### 4. Provide Default Values

```crystal
struct UserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter newsletter : Bool
  getter notifications : Bool

  def initialize(@name = "", @email = "", @newsletter = false, @notifications = true)
  end
end
```

### 5. Use Meaningful Validation Messages

```crystal
validate name, presence: true, message: "Name is required"
validate email, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i,
  message: "Please enter a valid email address"
validate age, numericality: {greater_than: 0, less_than: 150},
  message: "Age must be between 1 and 149"
```

## Next Steps

Now that you understand request contracts:

1. **[Response Objects](responses.md)** - Structure your API responses
2. **[Endpoints](endpoints.md)** - Use request contracts in your endpoints
3. **[Validation](../features/validation.md)** - Advanced validation techniques
4. **[Testing](../testing.md)** - Test your request contracts
5. **[Error Handling](middleware.md)** - Handle validation errors gracefully

---

_Request contracts provide the foundation for type-safe, validated input handling in Azu applications. With comprehensive validation rules and clear error messages, they ensure data integrity and improve developer experience._

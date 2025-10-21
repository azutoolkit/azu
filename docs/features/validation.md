# Validation

Azu provides comprehensive input validation using the Schema library, offering type-safe validation with detailed error messages, custom validation rules, and seamless integration with request contracts.

## What is Validation?

Validation in Azu provides:

- **Type Safety**: Compile-time type checking for validation rules
- **Comprehensive Rules**: Built-in validation rules for common scenarios
- **Custom Validation**: Support for custom validation logic
- **Error Messages**: Detailed, actionable error messages
- **Integration**: Seamless integration with request contracts

## Basic Validation

### Simple Validation

```crystal
struct UserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  def initialize(@name = "", @email = "", @age = nil)
  end

  # Basic validation rules
  validate name, presence: true
  validate email, presence: true, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
  validate age, numericality: {greater_than: 0, less_than: 150}, allow_nil: true
end
```

### Validation Methods

```crystal
# Check if request is valid
if user_request.valid?
  # Process valid request
  process_user(user_request)
else
  # Handle validation errors
  handle_errors(user_request.errors)
end

# Force validation (raises exception if invalid)
begin
  user_request.validate!
rescue ValidationError => e
  # Handle validation error
end

# Get validation errors
errors = user_request.errors
error_messages = user_request.errors.map(&.message)
```

## Built-in Validation Rules

### Presence Validation

```crystal
struct PresenceRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter phone : String?

  def initialize(@name = "", @email = "", @phone = nil)
  end

  # Required fields
  validate name, presence: true
  validate email, presence: true

  # Optional fields (no presence validation)
  # phone is optional
end
```

### Length Validation

```crystal
struct LengthRequest
  include Azu::Request

  getter title : String
  getter description : String
  getter password : String

  def initialize(@title = "", @description = "", @password = "")
  end

  # Exact length
  validate title, length: {exactly: 50}

  # Minimum length
  validate password, length: {min: 8}

  # Maximum length
  validate description, length: {max: 500}

  # Range
  validate title, length: {min: 5, max: 100}
end
```

### Format Validation

```crystal
struct FormatRequest
  include Azu::Request

  getter email : String
  getter phone : String
  getter url : String
  getter username : String

  def initialize(@email = "", @phone = "", @url = "", @username = "")
  end

  # Email format
  validate email, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i

  # Phone format
  validate phone, format: /\A\+?[\d\s\-\(\)]+\z/

  # URL format
  validate url, format: /\Ahttps?:\/\/.+\z/

  # Username format (alphanumeric and underscores)
  validate username, format: /\A[a-zA-Z0-9_]+\z/
end
```

### Numerical Validation

```crystal
struct NumericalRequest
  include Azu::Request

  getter age : Int32
  getter price : Float64
  getter score : Int32?
  getter percentage : Float64?

  def initialize(@age = 0, @price = 0.0, @score = nil, @percentage = nil)
  end

  # Greater than
  validate age, numericality: {greater_than: 0}

  # Less than
  validate age, numericality: {less_than: 150}

  # Range
  validate age, numericality: {greater_than: 0, less_than: 150}

  # Allow nil
  validate score, numericality: {greater_than: 0, less_than: 100}, allow_nil: true

  # Float validation
  validate price, numericality: {greater_than: 0.0}
  validate percentage, numericality: {greater_than: 0.0, less_than: 100.0}, allow_nil: true
end
```

### Inclusion/Exclusion Validation

```crystal
struct InclusionRequest
  include Azu::Request

  getter status : String
  getter priority : String?
  getter role : String

  def initialize(@status = "", @priority = nil, @role = "")
  end

  # Must be one of the specified values
  validate status, inclusion: {in: ["active", "inactive", "pending"]}

  # Optional inclusion
  validate priority, inclusion: {in: ["low", "medium", "high"]}, allow_nil: true

  # Must not be one of the specified values
  validate role, exclusion: {in: ["admin", "root", "system"]}
end
```

## Custom Validation

### Custom Validation Methods

```crystal
struct CustomValidationRequest
  include Azu::Request

  getter password : String
  getter confirm_password : String
  getter username : String
  getter email : String

  def initialize(@password = "", @confirm_password = "", @username = "", @email = "")
  end

  # Custom validation methods
  validate password, custom: :validate_password_strength
  validate confirm_password, custom: :validate_password_match
  validate username, custom: :validate_username_availability
  validate email, custom: :validate_email_availability

  private def validate_password_strength
    return if @password.empty?

    # Check minimum length
    if @password.size < 8
      errors.add("password", "must be at least 8 characters long")
    end

    # Check for uppercase letter
    unless @password.match(/[A-Z]/)
      errors.add("password", "must contain at least one uppercase letter")
    end

    # Check for lowercase letter
    unless @password.match(/[a-z]/)
      errors.add("password", "must contain at least one lowercase letter")
    end

    # Check for number
    unless @password.match(/\d/)
      errors.add("password", "must contain at least one number")
    end

    # Check for special character
    unless @password.match(/[!@#$%^&*(),.?":{}|<>]/)
      errors.add("password", "must contain at least one special character")
    end
  end

  private def validate_password_match
    return if @confirm_password.empty?

    if @password != @confirm_password
      errors.add("confirm_password", "must match password")
    end
  end

  private def validate_username_availability
    return if @username.empty?

    # Check if username is available
    if User.exists?(username: @username)
      errors.add("username", "is already taken")
    end

    # Check for reserved usernames
    reserved_usernames = ["admin", "root", "system", "api", "www"]
    if reserved_usernames.includes?(@username.downcase)
      errors.add("username", "is reserved")
    end
  end

  private def validate_email_availability
    return if @email.empty?

    # Check if email is available
    if User.exists?(email: @email)
      errors.add("email", "is already taken")
    end
  end
end
```

### Conditional Validation

```crystal
struct ConditionalValidationRequest
  include Azu::Request

  getter user_type : String
  getter company_name : String?
  getter personal_email : String?
  getter business_email : String?

  def initialize(@user_type = "", @company_name = nil, @personal_email = nil, @business_email = nil)
  end

  validate user_type, inclusion: {in: ["individual", "business"]}

  # Company name required for business users
  validate company_name, presence: true, if: :business_user?

  # Personal email required for individual users
  validate personal_email, presence: true, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i, if: :individual_user?

  # Business email required for business users
  validate business_email, presence: true, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i, if: :business_user?

  private def business_user?
    @user_type == "business"
  end

  private def individual_user?
    @user_type == "individual"
  end
end
```

## Error Handling

### Validation Error Response

```crystal
struct ValidationErrorResponse
  include Azu::Response

  def initialize(@errors : Hash(String, Array(String)))
  end

  def render
    {
      "Status" => "Unprocessable Entity",
      "Title" => "Validation Error",
      "Detail" => "The request could not be processed due to validation errors.",
      "FieldErrors" => @errors,
      "Timestamp" => Time.utc.to_rfc3339
    }.to_json
  end
end
```

### Error Handling in Endpoints

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

    # Process valid request
    user = create_user(create_user_request)
    UserResponse.new(user)
  end
end
```

## Advanced Validation

### Nested Object Validation

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

### Array Validation

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

### File Validation

```crystal
struct FileUploadRequest
  include Azu::Request

  getter file : HTTP::FormData::File
  getter description : String?

  def initialize(@file = HTTP::FormData::File.new("", "", "", 0), @description = nil)
  end

  # File type validation
  validate file, file_type: ["image/jpeg", "image/png", "image/gif", "application/pdf"]

  # File size validation
  validate file, file_size: {max: 10.megabytes}

  # Custom file validation
  validate file, custom: :validate_file_content

  validate description, length: {max: 500}, allow_nil: true

  private def validate_file_content
    return if @file.content.empty?

    # Check file signature
    case @file.content_type
    when "image/jpeg"
      unless @file.content.starts_with?([0xFF, 0xD8, 0xFF])
        errors.add("file", "Invalid JPEG file")
      end
    when "image/png"
      unless @file.content.starts_with?([0x89, 0x50, 0x4E, 0x47])
        errors.add("file", "Invalid PNG file")
      end
    when "application/pdf"
      unless @file.content.starts_with?("%PDF")
        errors.add("file", "Invalid PDF file")
      end
    end
  end
end
```

## Validation Testing

### Unit Testing

```crystal
require "spec"

describe UserRequest do
  it "validates required fields" do
    request = UserRequest.new(name: "", email: "")

    request.valid?.should be_false
    request.errors.any? { |e| e.field == "name" }.should be_true
    request.errors.any? { |e| e.field == "email" }.should be_true
  end

  it "validates email format" do
    request = UserRequest.new(name: "Alice", email: "invalid-email")

    request.valid?.should be_false
    request.errors.any? { |e| e.field == "email" }.should be_true
  end

  it "accepts valid data" do
    request = UserRequest.new(
      name: "Alice",
      email: "alice@example.com",
      age: 30
    )

    request.valid?.should be_true
  end
end
```

### Integration Testing

```crystal
describe "Validation Integration" do
  it "handles validation errors in endpoints" do
    request = CreateUserRequest.new(name: "", email: "invalid")
    endpoint = CreateUserEndpoint.new

    expect_raises(Azu::Response::ValidationError) do
      endpoint.call
    end
  end

  it "processes valid requests" do
    request = CreateUserRequest.new(
      name: "Alice",
      email: "alice@example.com",
      age: 30
    )

    endpoint = CreateUserEndpoint.new
    response = endpoint.call

    response.should be_a(UserResponse)
  end
end
```

## Performance Considerations

### Lazy Validation

```crystal
class LazyValidationRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  validate name, presence: true
  validate email, presence: true, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i

  # Lazy validation for expensive operations
  validate email, custom: :validate_email_availability, if: :email_present?

  private def email_present?
    !@email.empty?
  end

  private def validate_email_availability
    # Only validate if email is present
    return if @email.empty?

    # Expensive database check
    if User.exists?(email: @email)
      errors.add("email", "is already taken")
    end
  end
end
```

### Validation Caching

```crystal
class CachedValidationRequest
  include Azu::Request

  getter username : String

  def initialize(@username = "")
  end

  validate username, presence: true, custom: :validate_username_availability

  private def validate_username_availability
    return if @username.empty?

    # Check cache first
    cache_key = "username_available:#{@username}"
    if cached = Azu.cache.get(cache_key)
      unless cached == "true"
        errors.add("username", "is already taken")
      end
      return
    end

    # Check database
    available = !User.exists?(username: @username)

    # Cache result
    Azu.cache.set(cache_key, available.to_s, ttl: 1.hour)

    unless available
      errors.add("username", "is already taken")
    end
  end
end
```

## Best Practices

### 1. Use Appropriate Validation Rules

```crystal
# Good: Appropriate validation rules
validate email, presence: true, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
validate age, numericality: {greater_than: 0, less_than: 150}
validate password, length: {min: 8}

# Avoid: Overly restrictive rules
validate email, format: /\A[a-z]+@[a-z]+\.[a-z]+\z/  # Too restrictive
validate age, numericality: {greater_than: 18, less_than: 65}  # Too restrictive
```

### 2. Provide Clear Error Messages

```crystal
# Good: Clear error messages
validate name, presence: true, message: "Name is required"
validate email, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i,
  message: "Please enter a valid email address"
validate age, numericality: {greater_than: 0, less_than: 150},
  message: "Age must be between 1 and 149"

# Avoid: Generic error messages
validate name, presence: true  # Generic message
validate email, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i  # Generic message
```

### 3. Use Conditional Validation

```crystal
# Good: Conditional validation
validate company_name, presence: true, if: :business_user?
validate personal_email, presence: true, if: :individual_user?

# Avoid: Always validating optional fields
validate company_name, presence: true  # Always required
validate personal_email, presence: true  # Always required
```

### 4. Handle Validation Errors Gracefully

```crystal
# Good: Handle errors gracefully
def call : UserResponse
  unless request.valid?
    raise Azu::Response::ValidationError.new(
      request.errors.group_by(&.field).transform_values(&.map(&.message))
    )
  end

  # Process valid request
end

# Avoid: Ignoring validation errors
def call : UserResponse
  # No validation check
  process_request
end
```

### 5. Test Validation Thoroughly

```crystal
# Good: Test all validation scenarios
describe "Validation" do
  it "validates required fields" do
    # Test missing required fields
  end

  it "validates field formats" do
    # Test invalid formats
  end

  it "validates field lengths" do
    # Test length constraints
  end

  it "validates custom rules" do
    # Test custom validation
  end
end
```

## Next Steps

Now that you understand validation:

1. **[Request Contracts](requests.md)** - Use validation in request contracts
2. **[Error Handling](middleware.md)** - Handle validation errors
3. **[Testing](../testing.md)** - Test validation rules
4. **[Security](../advanced/security.md)** - Implement security validation
5. **[Performance](../advanced/performance.md)** - Optimize validation performance

---

_Validation in Azu provides a powerful way to ensure data integrity and security. With comprehensive rules, custom validation, and detailed error messages, it makes building robust applications straightforward and reliable._

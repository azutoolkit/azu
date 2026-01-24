# Request Reference

Request contracts define the expected shape of incoming request data with validation.

## Including Request

```crystal
struct MyRequest
  include Azu::Request

  getter field1 : String
  getter field2 : Int32?

  def initialize(@field1 = "", @field2 = nil)
  end
end
```

## Validation Macros

### validate

Add validation rules to a field.

```crystal
validate field_name, rule: value, ...
```

**Available Rules:**

| Rule | Description | Example |
|------|-------------|---------|
| `presence` | Field must not be empty | `presence: true` |
| `length` | String length constraints | `length: {min: 2, max: 100}` |
| `format` | Regex pattern match | `format: /@/` |
| `numericality` | Numeric constraints | `numericality: {greater_than: 0}` |
| `inclusion` | Value in set | `inclusion: {in: ["a", "b"]}` |
| `exclusion` | Value not in set | `exclusion: {in: ["admin"]}` |

### presence

Validate field is not empty/nil.

```crystal
validate name, presence: true
```

### length

Validate string length.

```crystal
validate name, length: {min: 2}           # At least 2 chars
validate name, length: {max: 100}         # At most 100 chars
validate name, length: {min: 2, max: 100} # Between 2 and 100
validate code, length: {is: 6}            # Exactly 6 chars
```

**Options:**
- `min : Int32` - Minimum length
- `max : Int32` - Maximum length
- `is : Int32` - Exact length

### format

Validate against regular expression.

```crystal
validate email, format: /@/
validate phone, format: /^\d{10}$/
validate slug, format: /^[a-z0-9-]+$/
```

### numericality

Validate numeric values.

```crystal
validate age, numericality: {greater_than: 0}
validate age, numericality: {greater_than_or_equal_to: 18}
validate age, numericality: {less_than: 150}
validate age, numericality: {less_than_or_equal_to: 120}
validate quantity, numericality: {equal_to: 1}
```

**Options:**
- `greater_than : Number`
- `greater_than_or_equal_to : Number`
- `less_than : Number`
- `less_than_or_equal_to : Number`
- `equal_to : Number`

### inclusion

Validate value is in allowed set.

```crystal
validate status, inclusion: {in: ["pending", "active", "archived"]}
validate role, inclusion: {in: Role.values.map(&.to_s)}
```

### exclusion

Validate value is not in forbidden set.

```crystal
validate username, exclusion: {in: ["admin", "root", "system"]}
```

## Instance Methods

### valid?

Check if request passes all validations.

```crystal
request = MyRequest.new(name: "")
request.valid?  # => false
```

**Returns:** `Bool`

### errors

Get validation errors.

```crystal
request.errors  # => Array(Error)
request.errors.each do |error|
  puts "#{error.field}: #{error.message}"
end
```

**Returns:** `Array(Error)`

### validate

Override to add custom validation logic.

```crystal
def validate
  super  # Run standard validations

  if custom_condition_fails
    errors << Error.new(:field, "custom message")
  end
end
```

## Error Class

### Azu::Request::Error

Represents a validation error.

```crystal
Error.new(field : Symbol, message : String)
```

**Properties:**
- `field : Symbol` - Field name
- `message : String` - Error message

## EmptyRequest

Use for endpoints that don't accept body data.

```crystal
struct GetUserEndpoint
  include Azu::Endpoint(EmptyRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    # No request body to parse
  end
end
```

## Request Parsing

Requests are automatically parsed from:
- JSON body (`application/json`)
- Form data (`application/x-www-form-urlencoded`)
- Multipart form (`multipart/form-data`)

## File Uploads

Handle file uploads with `HTTP::FormData::File`:

```crystal
struct UploadRequest
  include Azu::Request

  getter file : HTTP::FormData::File
  getter description : String?

  def initialize(@file, @description = nil)
  end
end
```

**File Properties:**
- `filename : String?` - Original filename
- `body : IO` - File content
- `headers : HTTP::Headers` - File headers

## Complete Example

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter password : String
  getter age : Int32?
  getter role : String

  def initialize(
    @name = "",
    @email = "",
    @password = "",
    @age = nil,
    @role = "user"
  )
  end

  validate name, presence: true, length: {min: 2, max: 100}
  validate email, presence: true, format: /@/
  validate password, presence: true, length: {min: 8}
  validate age, numericality: {greater_than: 0, less_than: 150}, allow_nil: true
  validate role, inclusion: {in: ["user", "admin", "moderator"]}

  def validate
    super

    if email_taken?(email)
      errors << Error.new(:email, "is already taken")
    end
  end

  private def email_taken?(email : String) : Bool
    User.exists?(email: email)
  end
end
```

## See Also

- [Endpoint Reference](endpoint.md)
- [Response Reference](response.md)
- [How to Validate Requests](../../how-to/validation/validate-requests.md)

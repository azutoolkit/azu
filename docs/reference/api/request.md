---
description: Request contracts define the expected shape of incoming request data and the validation rules it must pass.
---

# Request

A request contract is a struct that includes `Azu::Request`: the typed fields an endpoint reads from the body, the
query string and the path, and the validation rules they must pass. It comes with `require "azu"`. An endpoint
builds and checks it before `call` runs; a request that breaks it never reaches `call`. It is not the
`HTTP::Request` (that is `context.request`), and uploaded files are not part of it.

```crystal
struct MyRequest
  include Azu::Request

  getter field1 : String
  getter field2 : Int32?

  def initialize(@field1 = "", @field2 = nil)
  end
end
```

Including `Azu::Request` adds `JSON::Serializable`, `URI::Params::Serializable` and the
[Schema](https://github.com/eliasjpr/schema) validation macros, so a contract can be built with
`MyRequest.new`, `MyRequest.from_json(string)` or `MyRequest.from_www_form(string)`
(`from_query` is an alias of `from_www_form`).

## API

### validate

Add validation rules to a field. A field can carry several rules, and `message:` replaces the default
message (`Invalid field: <name>`) of every rule on that line.

<!-- skip -->
```crystal
validate field_name, rule: value, ..., message: "Custom message"
```

**Available Rules:**

| Rule | Description | Example |
|------|-------------|---------|
| `presence` | A `String` or collection must not be nil or empty | `presence: true` |
| `required` | Value must not be `nil` | `required: true` |
| `size` | Exact size (`Int`) or size within a `Range` | `size: 2..100` |
| `match` | `String` matches a `Regex` | `match: /@/` |
| `in` | Value is in an `Array` or `Range` | `in: %w(a b)` |
| `exclude` | Value is not in an `Array` or `Range` | `exclude: %w(admin)` |
| `eq` | Value equals the given value | `eq: 1` |
| `gt`, `gte`, `lt`, `lte` | Number (`Int` or `Float`) or `Time` comparison | `gt: 0` |

### presence

Validate field is not empty.

```crystal
struct NameRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  validate name, presence: true
end
```

### size

Validate string length, or the size of a collection.

```crystal
struct CodeRequest
  include Azu::Request

  getter name : String
  getter code : String

  def initialize(@name = "", @code = "")
  end

  validate name, size: 2..100 # Between 2 and 100 chars
  validate code, size: 6      # Exactly 6 chars
end
```

### match

Validate against a regular expression.

```crystal
struct ContactRequest
  include Azu::Request

  getter email : String
  getter phone : String
  getter slug : String

  def initialize(@email = "", @phone = "", @slug = "")
  end

  validate email, match: /@/
  validate phone, match: /^\d{10}$/
  validate slug, match: /^[a-z0-9-]+$/
end
```

### Comparisons

Validate numbers and times with `gt`, `gte`, `lt`, `lte` and `eq`. The compared value must have the same kind of
type as the field (an `Int32` field against an integer, a `Float64` field against a float).

```crystal
struct AgeRequest
  include Azu::Request

  getter age : Int32
  getter quantity : Int32

  def initialize(@age = 0, @quantity = 1)
  end

  validate age, gt: 0
  validate age, lt: 150
  validate quantity, eq: 1
end
```

### in

Validate value is in an allowed set.

```crystal
struct StatusRequest
  include Azu::Request

  getter status : String
  getter page : Int32

  def initialize(@status = "pending", @page = 1)
  end

  validate status, in: %w(pending active archived)
  validate page, in: 1..100
end
```

### exclude

Validate value is not in a forbidden set.

```crystal
struct UsernameRequest
  include Azu::Request

  getter username : String

  def initialize(@username = "")
  end

  validate username, exclude: %w(admin root system), message: "is reserved"
end
```

### valid?

Check if request passes all validations.

<!-- prelude -->
```crystal
struct NamedRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  validate name, presence: true
end

request = NamedRequest.new(name: "")
request.valid? # => false
```

**Returns:** `Bool`

### errors

Get validation errors.

```crystal
request = NamedRequest.new(name: "")
request.errors # => Array(Schema::Error)
request.errors.each do |error|
  puts "#{error.field}: #{error.message}"
end
request.error_messages # => Array(String)
```

**Returns:** `Array(Schema::Error)`

### validate!

Raise when the request is invalid.

```crystal
NamedRequest.new(name: "").validate! # raises Schema::Validation::ValidationError
```

### Custom validators

Rules that need code subclass `Schema::Validator`, return the errors from `valid?` and are registered with
`use`. The validator receives the request as `@record`.

```crystal
struct SignupRequest
  include Azu::Request

  getter email : String

  def initialize(@email = "")
  end

  validate email, presence: true
  use UniqueEmailValidator
end

class UniqueEmailValidator < Schema::Validator
  TAKEN = ["ada@example.com"]

  def initialize(@record : SignupRequest)
  end

  def valid? : Array(Schema::Error)
    errors = [] of Schema::Error
    errors << Schema::Error.new(:email, "has already been taken") if TAKEN.includes?(@record.email)
    errors
  end
end
```

### Schema::Error

Represents a validation error.

```crystal
Schema::Error.new(:email, "is already taken")
```

**Properties:**
- `field : Symbol` - Field name
- `message : String` - Error message

### Requests without a contract

Use the bare `Azu::Request` module for endpoints that have no body data to validate. They are not affected by
contract enforcement.

```crystal
struct UserResponse
  include Azu::Response

  def render
    "user"
  end
end

struct GetUserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    UserResponse.new
  end
end
```

### File uploads

Uploaded files are not part of the contract. Read them from `params.files` in the endpoint; each one is an
`Azu::Params::Multipart::File`:

```crystal
struct UploadRequest
  include Azu::Request

  getter description : String?

  def initialize(@description = nil)
  end
end

struct UploadResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    @name
  end
end

struct UploadEndpoint
  include Azu::Endpoint(UploadRequest, UploadResponse)

  post "/uploads"

  def call : UploadResponse
    file = params.files["file"]
    UploadResponse.new(file.filename || "unnamed")
  end
end
```

**File Properties:**
- `filename : String?` - Original filename
- `file : ::File` - The temp file holding the content
- `size : UInt64?` - Size in bytes
- `headers : HTTP::Headers` - File headers

## Behavior

### Request parsing

The contract is built once per call from:
- JSON body (`application/json`), with `from_json`
- Form data (`application/x-www-form-urlencoded`) and the query string, with `from_www_form`

A request that breaks its contract never reaches `call`: the endpoint answers it itself, also without `Rescuer` in
the chain, with:

| Status | When |
|---|---|
| `400` | The body or a field cannot be read as the contract's types, or the `Content-Type` header is malformed |
| `413` | The body is larger than `upload.max_file_size` |
| `422` | A validation rule fails; the body lists the failing fields (see [ValidationError](response.md#validationerror)) |

{% hint style="warning" %}
Neither `Rescuer` nor the router answers these, so a handler that rescues `Azu::Response::ValidationError` never
sees them; handlers around the endpoint still see the final status code.
{% endhint %}

## See also

- [Endpoint](endpoint.md)
- [Response](response.md)
- [Validate requests](../../how-to/validation/validate-requests.md)

# Contracts

This document explains the contract pattern in Azu, where explicit request and response types create clear interfaces between components.

## What are Contracts?

Contracts are type definitions that specify the shape of data flowing through your application:

- **Request contracts** define expected input
- **Response contracts** define expected output

Together, they create a clear API contract that's enforced by the compiler.

## The Contract Pattern

### Traditional Approach

Without contracts, data shapes are implicit:

```ruby
def create
  # What fields are expected?
  name = params[:name]
  email = params[:email]

  # What if name is missing? Runtime error
  # What if email is wrong type? Runtime error
end
```

### Contract Approach

With contracts, expectations are explicit:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end
end
```

Benefits:
- Self-documenting
- Validated automatically
- Type-checked at compile time

## Request Contracts

Request contracts define what data endpoints accept:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?  # Optional

  def initialize(@name = "", @email = "", @age = nil)
  end

  validate name, presence: true, size: 2..100
  validate email, presence: true, match: /@/
end
```

### Components

1. **Fields** - Properties that will be populated
2. **Types** - Crystal types (String, Int32, etc.)
3. **Optionality** - Use `?` for optional fields
4. **Validations** - Rules applied before processing

### Parsing

Request contracts are built from:
- JSON bodies (`application/json`)
- Form data (`application/x-www-form-urlencoded`) and the query string

Uploaded files of multipart forms are read from `params.files` in the endpoint rather than from the contract.

## Response Contracts

Response contracts define what endpoints return:

```crystal
struct User
  getter id : Int64
  getter name : String
  getter email : String

  def initialize(@id, @name, @email)
  end
end

struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id:    @user.id,
      name:  @user.name,
      email: @user.email,
    }.to_json
  end
end
```

### Components

1. **Constructor** - Accepts data to render
2. **Render method** - Produces output string
3. **Content type** - Implicit or explicit

### Return Type Enforcement

The compiler ensures you return the declared type. This endpoint does not compile, which is the point:

<!-- skip -->
```crystal
struct MyEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/mine"

  def call : UserResponse
    # Must return UserResponse
    "string" # Compile error!
  end
end
```

## Contract Benefits

### 1. Self-Documentation

Contracts document the API:

```crystal
struct SearchRequest
  include Azu::Request

  getter query : String         # Search term
  getter page : Int32 = 1       # Page number
  getter per_page : Int32 = 20  # Results per page
  getter sort : String = "date" # Sort field

  def initialize(@query = "")
  end
end
```

Reading the request tells you exactly what the API accepts.

### 2. Validation

Validations run before your code:

```crystal
struct OrderItem
  include JSON::Serializable
  include URI::Params::Serializable

  property product_id : Int64
  property quantity : Int32
end

struct CreateOrderRequest
  include Azu::Request

  getter items : Array(OrderItem)
  getter shipping_address : String
  getter payment_method : String

  def initialize(@items = [] of OrderItem, @shipping_address = "", @payment_method = "")
  end

  validate items, presence: true, message: "must have at least one item"
  validate shipping_address, presence: true
  validate payment_method, in: %w(card paypal bank)
end
```

Invalid requests never reach `call`: the endpoint answers `422` itself, with the failing fields
(see [Handle Validation Errors](../../how-to/validation/handle-validation-errors.md)).

### 3. Type Safety

Types are enforced at compile time:

```crystal
struct AgeRequest
  include Azu::Request

  getter age : Int32?

  def initialize(@age = nil)
  end
end

struct AgeEndpoint
  include Azu::Endpoint(AgeRequest, Azu::Response::Empty)

  post "/age"

  def call : Azu::Response::Empty
    # age is Int32?, not String
    if age = age_request.age
      check_age(age) # Compiler knows it's Int32
    end
    Azu::Response::Empty.new
  end

  private def check_age(age : Int32) : Bool
    age >= 18
  end
end
```

### 4. Refactoring Confidence

Changing contracts triggers compile errors:

<!-- skip -->
```crystal
# Before
struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end
end

# After - add required field
struct UserResponse
  include Azu::Response

  def initialize(@user : User, @permissions : Array(String))
  end
end

# All usages that don't provide permissions will fail to compile
```

## Empty Contracts

For endpoints without body data:

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
    # No request body to parse
    # Use params for route parameters
    id = params["id"]
    UserResponse.new
  end
end
```

For endpoints without response body:

```crystal
struct DeleteUserEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  delete "/users/:id"

  def call : Azu::Response::Empty
    # delete the user here
    status 204
    Azu::Response::Empty.new
  end
end
```

## Composition

Contracts can reference other types. A nested type includes both `JSON::Serializable` and `URI::Params::Serializable`,
because a contract is built from JSON and from form input, and an endpoint that uses the contract does not compile
without both:

```crystal
struct OrderItem
  include JSON::Serializable
  include URI::Params::Serializable
  property product_id : Int64
  property quantity : Int32
end

struct CreateOrderRequest
  include Azu::Request

  getter items : Array(OrderItem)
  getter notes : String?

  def initialize(@items = [] of OrderItem, @notes = nil)
  end
end
```

## Contract Versioning

For API versioning, create separate contracts:

```crystal
module V1
  struct UserResponse
    include Azu::Response

    def initialize(@name : String)
    end

    # V1 format
    def render
      {name: @name}.to_json
    end
  end
end

module V2
  struct UserResponse
    include Azu::Response

    def initialize(@name : String, @email : String)
    end

    # V2 format with additional fields
    def render
      {name: @name, email: @email}.to_json
    end
  end
end
```

## Best Practices

1. **One contract per use case**
   ```text
   struct CreateUserRequest    # For creation
   struct UpdateUserRequest    # For updates (might have optional fields)
   ```

2. **Use meaningful names**
   ```text
   struct SearchProductsRequest  # Clear purpose
   struct ProductListResponse    # Clear output
   ```

3. **Keep contracts focused**
   ```text
   # Good: focused response
   struct UserResponse
     def initialize(@user : User)
     end
   end

   # Avoid: kitchen-sink response
   struct BigResponse
     def initialize(@user, @posts, @comments, @notifications, ...)
     end
   end
   ```

## See Also

- [Endpoints](endpoints.md)
- [Why Contracts](../design-decisions/why-contracts.md)
- [Request Reference](../../reference/api/request.md)
- [Response Reference](../../reference/api/response.md)

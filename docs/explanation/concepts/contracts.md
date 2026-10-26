---
description: A contract is a type that states the shape of the data an endpoint takes or returns, so the compiler can check every use of it.
---

# Contracts

This page explains request and response contracts, what they give an application and what they cost.

## What are contracts?

Contracts are type definitions that specify the shape of data flowing through your application:

- **Request contracts** define expected input
- **Response contracts** define expected output

Together, they define the endpoint's API, and the compiler enforces it.

## The contract pattern

### Traditional approach

In many frameworks, request handling is implicit. In a Rails controller the shape of the input is spread over the
file:

```ruby
# Rails controller
def create
  @user = User.new(user_params)
  # What is user_params? What fields are allowed?
  # What validations apply? What if name is missing?
end

private

def user_params
  params.require(:user).permit(:name, :email, :age)
  # Scattered across the file
  # Not type-safe
  # Validation elsewhere
end
```

The input shape is not written down in one place, validation is separate from the definition, nothing is checked at
compile time, and a field is easy to miss.

### Contract approach

With contracts, expectations are explicit:

<!-- prelude -->
```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32? # Optional

  def initialize(@name = "", @email = "", @age = nil)
  end

  validate name, presence: true, size: 2..100
  validate email, presence: true, match: /@/
end
```

Everything about the input is in one place: the required fields, their types, the default values and the validation
rules. The contract is:
- Self-documenting
- Validated automatically
- Type-checked at compile time

## Request contracts

A request contract defines what data an endpoint accepts. `CreateUserRequest` above has the four parts of one.

### Components

1. **Fields** - Properties that will be populated
2. **Types** - Crystal types (String, Int32, etc.)
3. **Optionality** - Use `?` for optional fields
4. **Validations** - Rules applied before processing

### Parsing

Request contracts are built from:
- JSON bodies (`application/json`)
- Form data (`application/x-www-form-urlencoded`) and the query string

Input that cannot be converted to the declared types is answered with `400` before `call` runs. Uploaded files of
multipart forms are read from `params.files` in the endpoint rather than from the contract.

## Response contracts

Response contracts define what endpoints return:

<!-- prelude -->
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

### Return type enforcement

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

## Contract benefits

### 1. Self-documentation

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

Reading the request tells you exactly what the API accepts, and reading the response tells you what it returns. The
endpoint names both: `include Azu::Endpoint(CreateUserRequest, UserResponse)` is enough for a new developer to see
what goes in and what comes out.

### 2. Validation

Validations run before your code, and they live with the fields they check, so there is no hunting through other
files:

<!-- prelude -->
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

### 3. Type safety

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

### 4. Refactoring confidence

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

### 5. Testing

A contract needs no server to test: construct it and ask `valid?` and `errors`.

```crystal
require "spec"

describe CreateUserRequest do
  it "validates presence of name" do
    request = CreateUserRequest.new(name: "", email: "a@b.com")
    request.valid?.should be_false
    request.errors.map(&.field).should contain(:name)
  end

  it "validates email format" do
    request = CreateUserRequest.new(name: "Alice", email: "invalid")
    request.valid?.should be_false
  end
end
```

## Empty contracts

For endpoints without body data:

```crystal
struct GetUserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    # No request body to parse
    # Use params for route parameters
    id = params["id"].to_i64? || raise Azu::Response::NotFound.new("/users/#{params["id"]}")
    UserResponse.new(User.new(id, "Ada", "ada@example.com"))
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

Contracts can reference other types, as `CreateOrderRequest` does with `Array(OrderItem)`. A nested type includes
both `JSON::Serializable` and `URI::Params::Serializable`, because a contract is built from JSON and from form input,
and an endpoint that uses the contract does not compile without both.

The endpoint reads the nested values with their types, with no casting, no string parsing and no `nil` surprises:

```crystal
struct OrderResponse
  include Azu::Response

  def initialize(@units : Int32)
  end

  def render
    {units: @units}.to_json
  end
end

struct CreateOrderEndpoint
  include Azu::Endpoint(CreateOrderRequest, OrderResponse)

  post "/orders"

  def call : OrderResponse
    # Type is known: Array(OrderItem)
    items = create_order_request.items

    units = 0
    items.each do |item|
      # Type is known: OrderItem
      units += item.quantity
    end

    OrderResponse.new(units)
  end
end
```

## Contract versioning

For API versioning, create separate contracts, and let each version's endpoints use their own:

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

struct V1::UsersEndpoint
  include Azu::Endpoint(Azu::Request, V1::UserResponse)

  get "/v1/users"

  def call : V1::UserResponse
    V1::UserResponse.new("Ada")
  end
end

struct V2::UsersEndpoint
  include Azu::Endpoint(Azu::Request, V2::UserResponse)

  get "/v2/users"

  def call : V2::UserResponse
    V2::UserResponse.new("Ada", "ada@example.com")
  end
end
```

## Tooling reads contracts

Because the shape of the input and output is declared in types, tooling can read it. Azu itself builds an OpenAPI 3.1
document from the `Endpoint(Request, Response)` contracts of an app with `Azu::OpenAPI.document`, and
`Azu::OpenAPI::Handler` serves it (see [OpenAPI](../../reference/api/openapi.md)). The Azu CLI exports a
specification from a project with `azu openapi:export`, and can generate code from a specification with
`azu openapi:generate`.

## Trade-offs

### More boilerplate

Every endpoint that takes input needs a struct of its own: the fields, an `initialize` with defaults and the rules,
as `CreateUserRequest` shows.

### Rigid structure

Dynamic patterns are harder:

```ruby
# Ruby: Accept any fields
params.permit!
```

A contract must define all its fields. `JSON::Any` holds data that is truly dynamic:

```crystal
struct FlexibleRequest
  include Azu::Request

  getter name : String
  getter settings : Hash(String, JSON::Any)

  def initialize(@name = "", @settings = {} of String => JSON::Any)
  end
end
```

### Comparison

| Aspect | Implicit (params) | Explicit (contracts) |
|--------|------------------|---------------------|
| Discoverability | Low | High |
| Type safety | None | Full |
| Validation | Scattered | Colocated |
| Documentation | Manual | From the types |
| Testing | Complex | Simple |
| Refactoring | Risky | Safe |

## Why Azu uses contracts

Contracts follow from Azu's goals: explicit code over implicit conventions, errors found at compile time rather than
at runtime, documentation that is the code itself (types do not go out of date), and code that is easy to verify,
since a contract can be tested on its own.

## Best practices

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

## See also

- [Endpoints](endpoints.md)
- [Type safety](../architecture/type-safety.md)
- [Request](../../reference/api/request.md)
- [Response](../../reference/api/response.md)

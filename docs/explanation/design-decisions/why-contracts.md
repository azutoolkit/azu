# Why contracts?

This document explains why Azu uses explicit request and response contracts, and the benefits this pattern provides.

## The Problem

In many frameworks, request handling is implicit:

```ruby
# Rails controller
def create
  @user = User.new(user_params)
  # What is user_params?
  # What fields are allowed?
  # What validations apply?
end

private

def user_params
  params.require(:user).permit(:name, :email, :age)
  # Scattered across the file
  # Not type-safe
  # Validation elsewhere
end
```

Problems:
- Input shape isn't clear
- Validation is separate from definition
- No compile-time checking
- Easy to miss fields

## The Contract Solution

Contracts make everything explicit:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  def initialize(@name = "", @email = "", @age = nil)
  end

  validate name, presence: true, size: 2..100
  validate email, presence: true, match: /@/
end
```

Everything in one place:
- Required fields
- Types
- Validation rules
- Default values

## API as Interface

Contracts define your API interface:

### Request Contract = API Input

```crystal
struct SearchProductsRequest
  include Azu::Request

  getter query : String        # Required search term
  getter category : String?    # Optional filter
  getter min_price : Float64?  # Optional minimum
  getter max_price : Float64?  # Optional maximum
  getter page : Int32 = 1      # Default: first page
  getter per_page : Int32 = 20 # Default: 20 items
end
```

Reading this tells you exactly what the API accepts.

### Response Contract = API Output

```crystal
struct Product
  getter id : Int64
  getter name : String

  def initialize(@id, @name)
  end
end

struct ProductSearchResponse
  include Azu::Response

  def initialize(
    @products : Array(Product),
    @total : Int64,
    @page : Int32,
  )
  end

  def render
    {
      data: @products.map { |p| {id: p.id, name: p.name} },
      meta: {total: @total, page: @page},
    }.to_json
  end
end
```

Reading this tells you exactly what the API returns.

## Validation Colocation

Validation rules live with the data definition:

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

  # Validation right here with the fields
  validate items, presence: true, size: 0..100, message: "must have between 1 and 100 items"
  validate shipping_address, presence: true
  validate payment_method, in: %w(card paypal)
end
```

No hunting through multiple files.

## Type-Safe Access

Contracts provide typed access:

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

  def initialize(@items = [] of OrderItem)
  end
end

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

No casting, no string parsing, no nil surprises.

## Self-Documenting Code

Contracts document themselves:

<!-- skip -->
```crystal
# What does this endpoint accept?
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)
  #                     ↑ Look here         ↑ Look here
end
```

New developers can understand the API by reading types.

## Versioning

Contracts make versioning explicit:

```crystal
module V1
  struct UserResponse
    include Azu::Response

    # V1 fields
    def render
      {name: "Ada"}.to_json
    end
  end
end

module V2
  struct UserResponse
    include Azu::Response

    # V2 fields (breaking changes)
    def render
      {full_name: "Ada Lovelace"}.to_json
    end
  end
end

# Different endpoints use different versions
struct V1::UsersEndpoint
  include Azu::Endpoint(Azu::Request, V1::UserResponse)

  get "/v1/users"

  def call : V1::UserResponse
    V1::UserResponse.new
  end
end

struct V2::UsersEndpoint
  include Azu::Endpoint(Azu::Request, V2::UserResponse)

  get "/v2/users"

  def call : V2::UserResponse
    V2::UserResponse.new
  end
end
```

## Testing Benefits

Contracts are easy to test:

```crystal
require "azu"
require "spec"

struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  validate name, presence: true
  validate email, match: /@/
end

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

A contract needs no server to test: construct it and ask `valid?` and `errors`.

## Code Generation

Because the shape of the input and output is declared in types, tooling can read it. The Azu CLI exports an OpenAPI
specification from the contracts of a project with `azu openapi:export`, and can generate code from a specification
with `azu openapi:generate`.

## Comparison

| Aspect | Implicit (params) | Explicit (contracts) |
|--------|------------------|---------------------|
| Discoverability | Low | High |
| Type safety | None | Full |
| Validation | Scattered | Colocated |
| Documentation | Manual | From the types |
| Testing | Complex | Simple |
| Refactoring | Risky | Safe |

## Trade-offs

### More Boilerplate

```crystal
# Extra struct definition needed
struct MyRequest
  include Azu::Request

  getter field : String

  def initialize(@field = "")
  end
end
```

### Rigid Structure

Dynamic patterns are harder:

```ruby
# Ruby: Accept any fields
params.permit!
```

```crystal
# Crystal: Must define all fields
# Can use JSON::Any for truly dynamic data
struct FlexibleRequest
  include Azu::Request

  getter name : String
  getter settings : Hash(String, JSON::Any)

  def initialize(@name = "", @settings = {} of String => JSON::Any)
  end
end
```

## The Azu Philosophy

Contracts align with Azu's goals:

1. **Explicit over implicit** - Clear code beats magic
2. **Compile-time over runtime** - Catch errors early
3. **Documentation as code** - Types don't lie
4. **Testing support** - Easy to verify

## See Also

- [Contracts Concept](../concepts/contracts.md)
- [Why Type Safety](why-type-safety.md)
- [Request Reference](../../reference/api/request.md)
- [Response Reference](../../reference/api/response.md)

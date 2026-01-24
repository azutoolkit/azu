# Why Contracts?

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

  validate name, presence: true, length: {min: 2}
  validate email, presence: true, format: /@/
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

  getter query : String           # Required search term
  getter category : String?       # Optional filter
  getter min_price : Float64?     # Optional minimum
  getter max_price : Float64?     # Optional maximum
  getter page : Int32 = 1         # Default: first page
  getter per_page : Int32 = 20    # Default: 20 items
end
```

Reading this tells you exactly what the API accepts.

### Response Contract = API Output

```crystal
struct ProductSearchResponse
  include Azu::Response

  def initialize(
    @products : Array(Product),
    @total : Int64,
    @page : Int32
  )
  end

  def render
    {
      data: @products.map { |p| serialize(p) },
      meta: {total: @total, page: @page}
    }.to_json
  end
end
```

Reading this tells you exactly what the API returns.

## Validation Colocation

Validation rules live with the data definition:

```crystal
struct CreateOrderRequest
  include Azu::Request

  getter items : Array(OrderItem)
  getter shipping_address : String
  getter payment_method : String

  # Validation right here with the fields
  validate items, presence: true
  validate shipping_address, presence: true
  validate payment_method, inclusion: {in: ["card", "paypal"]}

  # Custom validation in the same struct
  def validate
    super
    errors << Error.new(:items, "too many") if items.size > 100
  end
end
```

No hunting through multiple files.

## Type-Safe Access

Contracts provide typed access:

```crystal
def call : OrderResponse
  # Type is known: Array(OrderItem)
  items = create_order_request.items

  items.each do |item|
    # Type is known: OrderItem
    process(item.product_id, item.quantity)
  end
end
```

No casting, no string parsing, no nil surprises.

## Self-Documenting Code

Contracts document themselves:

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
  end
end

module V2
  struct UserResponse
    include Azu::Response
    # V2 fields (breaking changes)
  end
end

# Different endpoints use different versions
struct V1::UsersEndpoint
  include Azu::Endpoint(Request, V1::UserResponse)
end

struct V2::UsersEndpoint
  include Azu::Endpoint(Request, V2::UserResponse)
end
```

## Testing Benefits

Contracts are easy to test:

```crystal
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

## Code Generation

Contracts enable tooling:

```crystal
# Generate OpenAPI spec from contracts
OpenAPI.generate(CreateUserRequest)
# => {
#      type: "object",
#      required: ["name", "email"],
#      properties: {
#        name: {type: "string", minLength: 2},
#        email: {type: "string", format: "email"}
#      }
#    }
```

## Comparison

| Aspect | Implicit (params) | Explicit (contracts) |
|--------|------------------|---------------------|
| Discoverability | Low | High |
| Type safety | None | Full |
| Validation | Scattered | Colocated |
| Documentation | Manual | Automatic |
| Testing | Complex | Simple |
| Refactoring | Risky | Safe |

## Trade-offs

### More Boilerplate

```crystal
# Extra struct definition needed
struct MyRequest
  include Azu::Request
  getter field : String
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

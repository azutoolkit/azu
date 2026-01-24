# Understanding Endpoints

This document explains the concept of endpoints in Azu and how they provide a structured approach to handling HTTP requests.

## What is an Endpoint?

An endpoint is a structured handler for a specific HTTP route. It combines:

- **Route definition** - The HTTP method and path
- **Request contract** - Expected input shape
- **Response contract** - Output format
- **Business logic** - The actual handling code

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Business logic here
  end
end
```

## Why Endpoints?

### Traditional Approach Problems

In traditional MVC frameworks:

```ruby
class UsersController
  def create
    # What parameters are expected? Unknown until runtime
    # What response format? Could be anything
    # Is input valid? Must check manually
  end
end
```

### Azu's Solution

Endpoints make contracts explicit:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)
  #                     ↑ Input declared    ↑ Output declared

  post "/users"
  # Route is part of the endpoint, not separate

  def call : UserResponse
    # Input is validated before this runs
    # Return type is enforced by compiler
  end
end
```

## Endpoint Components

### 1. Route Declaration

The route macro registers the HTTP method and path:

```crystal
get "/users"           # GET request
post "/users"          # POST request
put "/users/:id"       # PUT with parameter
delete "/users/:id"    # DELETE request
```

Routes support:
- Static segments: `/users`
- Parameters: `:id`
- Wildcards: `*path`

### 2. Request Contract

The first type parameter defines expected input:

```crystal
include Azu::Endpoint(CreateUserRequest, UserResponse)
#                     ↑ This type
```

For endpoints without body data:

```crystal
include Azu::Endpoint(EmptyRequest, UserResponse)
```

### 3. Response Contract

The second type parameter defines the output:

```crystal
include Azu::Endpoint(CreateUserRequest, UserResponse)
#                                        ↑ This type

def call : UserResponse  # Must return this
  UserResponse.new(user)
end
```

### 4. Call Method

The `call` method contains business logic:

```crystal
def call : UserResponse
  # Access validated request data
  name = create_user_request.name

  # Perform business logic
  user = User.create!(name: name)

  # Return typed response
  UserResponse.new(user)
end
```

## Available Context

Inside `call`, you have access to:

```crystal
def call : UserResponse
  # Route parameters
  id = params["id"]

  # Request headers
  auth = headers["Authorization"]?

  # Full request object
  method = request.method
  path = request.path

  # Response object
  response.headers["X-Custom"] = "value"
  status 201

  # Full HTTP context
  context.request
  context.response
end
```

## Request Access Pattern

The request object is accessed via a generated method:

```crystal
struct CreateUserRequest
  include Azu::Request
  getter name : String
  getter email : String
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  def call : UserResponse
    # Method name is snake_case of request type
    create_user_request.name
    create_user_request.email
  end
end
```

## Single Responsibility

Each endpoint handles one route:

```crystal
# One endpoint per route
struct UsersIndex
  include Azu::Endpoint(EmptyRequest, UsersResponse)
  get "/users"
end

struct UsersShow
  include Azu::Endpoint(EmptyRequest, UserResponse)
  get "/users/:id"
end

struct UsersCreate
  include Azu::Endpoint(CreateUserRequest, UserResponse)
  post "/users"
end
```

Benefits:
- Clear responsibility
- Easy to find code
- Simple to test
- No action dispatch overhead

## Struct vs Class

Endpoints are typically structs:

```crystal
struct MyEndpoint  # Struct
  include Azu::Endpoint(Request, Response)
end
```

Why structs?
- Value semantics
- Stack allocation when possible
- Immutable by default
- Better performance

Use class only if you need:
- Inheritance
- Reference semantics
- Instance-level state (rare)

## Error Handling

Endpoints can raise typed errors:

```crystal
def call : UserResponse
  user = User.find?(params["id"])

  unless user
    raise Azu::Response::NotFound.new("/users/#{params["id"]}")
  end

  UserResponse.new(user)
end
```

The handler chain catches and converts these to HTTP responses.

## Testing Endpoints

Endpoints are easy to test in isolation:

```crystal
describe CreateUserEndpoint do
  it "creates a user" do
    context = create_test_context(
      method: "POST",
      path: "/users",
      body: {name: "Alice"}.to_json
    )

    endpoint = CreateUserEndpoint.new
    endpoint.context = context

    response = endpoint.call

    response.should be_a(UserResponse)
  end
end
```

## See Also

- [Contracts](contracts.md)
- [Endpoint Reference](../../reference/api/endpoint.md)
- [How to Create an Endpoint](../../how-to/endpoints/create-endpoint.md)

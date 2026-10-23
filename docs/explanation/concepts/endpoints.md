# Understanding Endpoints

This document explains the concept of endpoints in Azu and how they provide a structured approach to handling HTTP requests.

## What is an Endpoint?

An endpoint is a structured handler for a specific HTTP route. It combines:

- **Route definition** - The HTTP method and path
- **Request contract** - Expected input shape
- **Response contract** - Output format
- **Business logic** - The actual handling code

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  validate name, presence: true
end

struct UserResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    {name: @name}.to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Business logic here
    UserResponse.new(create_user_request.name)
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
struct CreateRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  validate name, presence: true
end

struct CreatedResponse
  include Azu::Response

  def render
    "created"
  end
end

struct CreateEndpoint
  include Azu::Endpoint(CreateRequest, CreatedResponse)
  #                     ↑ Input declared    ↑ Output declared

  post "/create"
  # Route is part of the endpoint, not separate

  def call : CreatedResponse
    # Input is validated before this runs
    # Return type is enforced by compiler
    CreatedResponse.new
  end
end
```

## Endpoint Components

### 1. Route Declaration

The route macro registers the HTTP method and path. Each endpoint declares one:

```crystal
struct RouteResponse
  include Azu::Response

  def render
  end
end

struct IndexEndpoint
  include Azu::Endpoint(Azu::Request, RouteResponse)

  get "/users" # GET request

  def call : RouteResponse
    RouteResponse.new
  end
end

struct UpdateEndpoint
  include Azu::Endpoint(Azu::Request, RouteResponse)

  put "/users/:id" # PUT with parameter

  def call : RouteResponse
    RouteResponse.new
  end
end

struct FilesEndpoint
  include Azu::Endpoint(Azu::Request, RouteResponse)

  get "/files/*path" # wildcard

  def call : RouteResponse
    RouteResponse.new
  end
end
```

Routes support:
- Static segments: `/users`
- Parameters: `:id`
- Wildcards: `*path`

### 2. Request Contract

The first type parameter defines expected input:

<!-- skip -->
```crystal
include Azu::Endpoint(CreateUserRequest, UserResponse)
#                     ↑ This type
```

For endpoints without body data, use the bare `Azu::Request` module. There is nothing to validate, so the endpoint is
not affected by contract enforcement:

```crystal
struct UserResponse
  include Azu::Response

  def render
    "user"
  end
end

struct ShowEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    UserResponse.new
  end
end
```

### 3. Response Contract

The second type parameter defines the output:

<!-- skip -->
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
struct CreateUserRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end
end

struct UserResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    {name: @name}.to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Access validated request data
    name = create_user_request.name

    # Perform business logic
    name = name.strip

    # Return typed response
    UserResponse.new(name)
  end
end
```

## Available Context

Inside `call`, you have access to:

```crystal
struct ContextEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/context/:id"

  def call : Azu::Response::Empty
    # Route, query and form parameters
    id = params["id"]

    # Request headers
    auth = header["Authorization"]?

    # The HTTP method of the request
    http_method = method

    # Response header and status
    header "X-Custom", "value"
    status 201

    # Full HTTP context
    path = context.request.path
    context.response

    Azu::Response::Empty.new
  end
end
```

## Request Access Pattern

The request object is accessed via a generated method:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end
end

struct UserResponse
  include Azu::Response

  def render
    "user"
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Method name is snake_case of request type
    create_user_request.name
    create_user_request.email
    UserResponse.new
  end
end
```

## Single Responsibility

Each endpoint handles one route:

```crystal
struct UsersResponse
  include Azu::Response

  def render
    "[]"
  end
end

struct UserResponse
  include Azu::Response

  def render
    "{}"
  end
end

struct CreateUserRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end
end

# One endpoint per route
struct UsersIndex
  include Azu::Endpoint(Azu::Request, UsersResponse)

  get "/users"

  def call : UsersResponse
    UsersResponse.new
  end
end

struct UsersShow
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    UserResponse.new
  end
end

struct UsersCreate
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    UserResponse.new
  end
end
```

Benefits:
- Clear responsibility
- Easy to find code
- Simple to test
- No action dispatch: the router calls the endpoint directly

## Struct vs Class

Endpoints are typically structs:

```crystal
struct PlainResponse
  include Azu::Response

  def render
    "ok"
  end
end

struct MyEndpoint # Struct
  include Azu::Endpoint(Azu::Request, PlainResponse)

  get "/my"

  def call : PlainResponse
    PlainResponse.new
  end
end
```

Why structs?
- Value semantics
- Nothing to inherit: an endpoint is a small, flat unit
- Request state lives in the call, not in fields you add

Use class only if you need:
- Inheritance
- Reference semantics
- Instance-level state (rare)

One instance of an endpoint serves every request to its route, so do not keep per-request data in your own
instance variables.

## Error Handling

Endpoints can raise typed errors:

```crystal
struct UserResponse
  include Azu::Response

  def render
    "user"
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    unless params["id"] == "1"
      raise Azu::Response::NotFound.new("/users/#{params["id"]}")
    end

    UserResponse.new
  end
end
```

The handler chain catches and converts these to HTTP responses (`Azu::Handler::Rescuer`).

## Testing Endpoints

Endpoints are easy to test in isolation: build an `HTTP::Server::Context` and call the endpoint with it.

```crystal
require "azu"
require "spec"

struct UserResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    {name: @name}.to_json
  end
end

struct CreateUserRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  validate name, presence: true
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    UserResponse.new(create_user_request.name)
  end
end

describe CreateUserEndpoint do
  it "creates a user" do
    io = IO::Memory.new
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    request = HTTP::Request.new("POST", "/users", headers, {name: "Alice"}.to_json)
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    CreateUserEndpoint.new.call(context)
    response.close

    io.to_s.should contain(%({"name":"Alice"}))
  end
end
```

## See Also

- [Contracts](contracts.md)
- [Endpoint Reference](../../reference/api/endpoint.md)
- [How to Create an Endpoint](../../how-to/endpoints/create-endpoint.md)

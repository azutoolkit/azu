# Endpoints

Endpoints are the heart of Azu applications. They define how your application responds to HTTP requests with type safety, validation, and clear separation of concerns.

## What are Endpoints?

An endpoint is a type-safe, testable object that handles a specific HTTP route. Each endpoint defines:

- **HTTP Methods**: Which HTTP methods it accepts (GET, POST, PUT, DELETE, etc.)
- **Route Pattern**: The URL pattern it handles
- **Request Contract**: What data it expects to receive
- **Response Object**: What data it returns
- **Business Logic**: How it processes the request

## Basic Endpoint Structure

```crystal
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    # Your business logic here
    UserResponse.new(find_user(params["id"]))
  end
end
```

### Key Components

1. **Module Include**: `include Azu::Endpoint(RequestType, ResponseType)`
2. **Route Declaration**: `get "/users/:id"`
3. **Call Method**: `def call : ResponseType` - the main logic

## HTTP Methods

Azu supports all standard HTTP methods:

```crystal
struct ApiEndpoint
  include Azu::Endpoint(ApiRequest, ApiResponse)

  get "/api/data"           # Retrieve data
  post "/api/data"          # Create new data
  put "/api/data/:id"       # Update existing data
  patch "/api/data/:id"     # Partial update
  delete "/api/data/:id"    # Delete data
  head "/api/data"          # Head request
  options "/api/data"       # Options request
  trace "/api/data"         # Trace request
end
```

### Multiple Routes

You can handle multiple routes in a single endpoint:

```crystal
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  get "/users"
  get "/users/:id"
  post "/users"
  put "/users/:id"
  delete "/users/:id"

  def call : UserResponse
    case context.request.method
    when "GET"
      handle_get
    when "POST"
      handle_post
    when "PUT"
      handle_put
    when "DELETE"
      handle_delete
    end
  end

  private def handle_get
    if params["id"]?
      show_user
    else
      list_users
    end
  end

  private def handle_post
    create_user
  end

  private def handle_put
    update_user
  end

  private def handle_delete
    delete_user
  end
end
```

## Request Contracts

Request contracts define and validate the data your endpoint expects:

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

### Accessing Request Data

In your endpoint, access validated request data:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Type-safe access to validated data
    user = User.new(
      name: create_user_request.name,
      email: create_user_request.email,
      age: create_user_request.age
    )

    UserResponse.new(user)
  end
end
```

### Validation

Request contracts automatically validate incoming data:

```crystal
def call : UserResponse
  # Check if request is valid
  unless create_user_request.valid?
    raise Azu::Response::ValidationError.new(
      create_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
    )
  end

  # Proceed with business logic
  create_user
end
```

## Response Objects

Response objects structure your endpoint's output:

```crystal
struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id: @user.id,
      name: @user.name,
      email: @user.email,
      created_at: @user.created_at.to_rfc3339
    }.to_json
  end
end
```

### Response Types

Azu provides several built-in response types:

```crystal
# JSON response
struct JsonResponse
  include Azu::Response

  def initialize(@data : Hash(String, JSON::Any))
  end

  def render
    @data.to_json
  end
end

# HTML response
struct HtmlResponse
  include Azu::Response
  include Azu::Templates::Renderable

  def initialize(@template : String, @data : Hash(String, JSON::Any))
  end

  def render
    view @template, @data
  end
end

# Text response
struct TextResponse
  include Azu::Response

  def initialize(@text : String)
  end

  def render
    @text
  end
end
```

## Route Parameters

Access URL parameters in your endpoints:

```crystal
struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request::Empty, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64

    if user = User.find(user_id)
      UserResponse.new(user)
    else
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end
  end
end
```

### Parameter Types

Parameters are automatically converted to the appropriate type:

```crystal
# String parameter
name = params["name"] # String

# Integer parameter
id = params["id"].to_i # Int32

# Float parameter
price = params["price"].to_f # Float64

# Boolean parameter
active = params["active"] == "true" # Bool
```

## Query Parameters

Access query string parameters:

```crystal
struct ListUsersEndpoint
  include Azu::Endpoint(Azu::Request::Empty, UsersListResponse)

  get "/users"

  def call : UsersListResponse
    # Access query parameters
    page = params["page"]?.try(&.to_i) || 1
    limit = params["limit"]?.try(&.to_i) || 10
    search = params["search"]?

    users = User.search(search).paginate(page, limit)
    UsersListResponse.new(users)
  end
end
```

## Request Context

Access the full HTTP request context:

```crystal
struct ApiEndpoint
  include Azu::Endpoint(ApiRequest, ApiResponse)

  def call : ApiResponse
    # Access request headers
    user_agent = context.request.headers["User-Agent"]?
    content_type = context.request.headers["Content-Type"]?

    # Access request body
    body = context.request.body.try(&.gets_to_end)

    # Set response headers
    context.response.headers["X-Custom-Header"] = "value"

    # Set response status
    status 201

    ApiResponse.new(process_data)
  end
end
```

## Error Handling

Handle errors gracefully in your endpoints:

```crystal
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  def call : UserResponse
    begin
      # Your business logic
      user = process_user_request
      UserResponse.new(user)
    rescue e : UserNotFoundError
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    rescue e : ValidationError
      raise Azu::Response::ValidationError.new(e.errors)
    rescue e
      Log.error(exception: e) { "Unexpected error in UserEndpoint" }
      raise Azu::Response::InternalServerError.new("Something went wrong")
    end
  end
end
```

### Common Error Responses

```crystal
# 400 Bad Request
raise Azu::Response::BadRequest.new("Invalid request format")

# 401 Unauthorized
raise Azu::Response::Unauthorized.new("Authentication required")

# 403 Forbidden
raise Azu::Response::Forbidden.new("Access denied")

# 404 Not Found
raise Azu::Response::NotFound.new("/users/999")

# 422 Unprocessable Entity
raise Azu::Response::ValidationError.new({"name" => ["Name is required"]})

# 500 Internal Server Error
raise Azu::Response::InternalServerError.new("Server error")
```

## Status Codes

Set appropriate HTTP status codes:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    user = create_user

    # Set 201 Created status
    status 201

    # Set Location header
    context.response.headers["Location"] = "/users/#{user.id}"

    UserResponse.new(user)
  end
end
```

### Common Status Codes

- **200 OK**: Successful GET, PUT, PATCH
- **201 Created**: Successful POST
- **204 No Content**: Successful DELETE
- **400 Bad Request**: Invalid request
- **401 Unauthorized**: Authentication required
- **403 Forbidden**: Access denied
- **404 Not Found**: Resource not found
- **422 Unprocessable Entity**: Validation errors
- **500 Internal Server Error**: Server error

## Content Types

Handle different content types:

```crystal
struct ApiEndpoint
  include Azu::Endpoint(ApiRequest, ApiResponse)

  def call : ApiResponse
    # Set content type
    content_type "application/json"

    # Or set based on request
    case context.request.headers["Accept"]?
    when "application/json"
      content_type "application/json"
    when "application/xml"
      content_type "application/xml"
    else
      content_type "application/json"
    end

    ApiResponse.new(data)
  end
end
```

## Testing Endpoints

Test your endpoints with Crystal's built-in testing framework:

```crystal
require "spec"
require "azu"

describe UserEndpoint do
  it "creates a user successfully" do
    request = CreateUserRequest.new(
      name: "Alice",
      email: "alice@example.com",
      age: 30
    )

    endpoint = UserEndpoint.new
    response = endpoint.call

    response.should be_a(UserResponse)
    response.user.name.should eq("Alice")
  end

  it "handles validation errors" do
    request = CreateUserRequest.new(
      name: "",  # Invalid: empty name
      email: "invalid-email"  # Invalid: bad format
    )

    endpoint = UserEndpoint.new

    expect_raises(Azu::Response::ValidationError) do
      endpoint.call
    end
  end
end
```

## Best Practices

### 1. Single Responsibility

Each endpoint should have a single, clear responsibility:

```crystal
# Good: Single responsibility
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)
  post "/users"
  def call : UserResponse; end
end

# Avoid: Multiple responsibilities
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)
  get "/users"
  post "/users"
  put "/users/:id"
  delete "/users/:id"
  # Too many responsibilities
end
```

### 2. Type Safety

Always use typed request and response objects:

```crystal
# Good: Type-safe
struct UserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)
end

# Avoid: Untyped
struct UserEndpoint
  include Azu::Endpoint(Azu::Request::Empty, Azu::Response::Text)
end
```

### 3. Error Handling

Handle errors gracefully and provide meaningful messages:

```crystal
def call : UserResponse
  begin
    user = find_user(params["id"])
    UserResponse.new(user)
  rescue e : UserNotFoundError
    raise Azu::Response::NotFound.new("User not found")
  rescue e
    Log.error(exception: e) { "Error in UserEndpoint" }
    raise Azu::Response::InternalServerError.new("Internal server error")
  end
end
```

### 4. Validation

Always validate input data:

```crystal
def call : UserResponse
  unless request.valid?
    raise Azu::Response::ValidationError.new(request.errors)
  end

  # Proceed with business logic
end
```

### 5. Status Codes

Use appropriate HTTP status codes:

```crystal
def call : UserResponse
  user = create_user

  # Set appropriate status
  status 201  # Created

  UserResponse.new(user)
end
```

## Advanced Patterns

### Resource Endpoints

Create RESTful resource endpoints:

```crystal
# Users resource
struct UsersResource
  include Azu::Endpoint(UsersRequest, UsersResponse)

  get "/users"
  post "/users"
  get "/users/:id"
  put "/users/:id"
  delete "/users/:id"

  def call : UsersResponse
    case context.request.method
    when "GET"
      if params["id"]?
        show_user
      else
        list_users
      end
    when "POST"
      create_user
    when "PUT"
      update_user
    when "DELETE"
      delete_user
    end
  end
end
```

### Nested Resources

Handle nested resources:

```crystal
struct UserPostsEndpoint
  include Azu::Endpoint(PostsRequest, PostsResponse)

  get "/users/:user_id/posts"
  post "/users/:user_id/posts"

  def call : PostsResponse
    user_id = params["user_id"].to_i64

    case context.request.method
    when "GET"
      list_user_posts(user_id)
    when "POST"
      create_user_post(user_id)
    end
  end
end
```

## Next Steps

Now that you understand endpoints:

1. **[Request Contracts](requests.md)** - Master request validation and type safety
2. **[Response Objects](responses.md)** - Structure your API responses
3. **[Routing](routing.md)** - Organize your application routes
4. **[Middleware](middleware.md)** - Customize request processing
5. **[Testing](../testing.md)** - Write comprehensive tests for your endpoints
6. **[WebSocket Channels](../features/websockets.md)** - Build real-time features

---

_Endpoints are the foundation of Azu applications. With type safety, validation, and clear separation of concerns, they make your code robust, testable, and maintainable._

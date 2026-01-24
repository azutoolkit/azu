# Endpoint Reference

Endpoints handle HTTP requests with type-safe request and response contracts.

## Including Endpoint

```crystal
struct MyEndpoint
  include Azu::Endpoint(RequestType, ResponseType)
end
```

**Type Parameters:**
- `RequestType` - Request contract type (must include `Azu::Request`)
- `ResponseType` - Response type (must include `Azu::Response`)

## HTTP Method Macros

### get

Define a GET endpoint.

```crystal
get "/path"
get "/users/:id"
get "/search"
```

### post

Define a POST endpoint.

```crystal
post "/users"
post "/login"
```

### put

Define a PUT endpoint.

```crystal
put "/users/:id"
```

### patch

Define a PATCH endpoint.

```crystal
patch "/users/:id"
```

### delete

Define a DELETE endpoint.

```crystal
delete "/users/:id"
```

### options

Define an OPTIONS endpoint.

```crystal
options "/users"
```

### head

Define a HEAD endpoint.

```crystal
head "/users/:id"
```

## Instance Methods

### call

Handle the request. Must be implemented.

```crystal
def call : ResponseType
  # Handle request and return response
end
```

**Returns:** `ResponseType`

### params

Access route and query parameters.

```crystal
def call
  id = params["id"]          # Route parameter
  page = params["page"]?     # Optional query parameter
end
```

**Returns:** `Hash(String, String)`

### headers

Access request headers.

```crystal
def call
  auth = headers["Authorization"]?
  content_type = headers["Content-Type"]?
end
```

**Returns:** `HTTP::Headers`

### context

Access the full HTTP context.

```crystal
def call
  context.request   # HTTP::Request
  context.response  # HTTP::Server::Response
end
```

**Returns:** `HTTP::Server::Context`

### request

Access the HTTP request.

```crystal
def call
  method = request.method
  path = request.path
  body = request.body
end
```

**Returns:** `HTTP::Request`

### response

Access the HTTP response.

```crystal
def call
  response.headers["X-Custom"] = "value"
  response.status_code = 201
end
```

**Returns:** `HTTP::Server::Response`

### status

Set the response status code.

```crystal
def call
  status 201  # Created
  status 204  # No Content
end
```

**Parameters:**
- `code : Int32` - HTTP status code

## Request Access

Access the typed request via generated method:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Access request via snake_case method name
    create_user_request.name
    create_user_request.email
  end
end
```

Method name is derived from request type: `CreateUserRequest` → `create_user_request`

## Response Helpers

### json

Return JSON response.

```crystal
def call
  json({message: "Hello", count: 42})
end
```

### text

Return plain text response.

```crystal
def call
  text "Hello, World!"
end
```

### html

Return HTML response.

```crystal
def call
  html "<h1>Hello</h1>"
end
```

### redirect_to

Redirect to another URL.

```crystal
def call
  redirect_to "/dashboard"
  redirect_to "/login", status: 301  # Permanent
end
```

**Parameters:**
- `url : String` - Redirect URL
- `status : Int32 = 302` - HTTP status code

## Route Parameters

### Path Parameters

```crystal
get "/users/:id"
get "/users/:user_id/posts/:post_id"

def call
  user_id = params["user_id"]
  post_id = params["post_id"]
end
```

### Wildcard Parameters

```crystal
get "/files/*path"

def call
  path = params["path"]  # Captures rest of path
end
```

## Complete Example

```crystal
struct UserEndpoint
  include Azu::Endpoint(EmptyRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64
    user = User.find?(user_id)

    unless user
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end

    UserResponse.new(user)
  end
end

struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id: @user.id,
      name: @user.name,
      email: @user.email
    }.to_json
  end
end
```

## See Also

- [Request Reference](request.md)
- [Response Reference](response.md)
- [Router Reference](router.md)

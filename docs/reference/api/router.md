# Router Reference

The router handles HTTP request routing using a radix tree for high performance.

## Route Registration

Routes are automatically registered when defining endpoints:

```crystal
struct MyEndpoint
  include Azu::Endpoint(EmptyRequest, MyResponse)

  get "/path"  # Registers GET /path

  def call : MyResponse
    # Handle request
  end
end
```

## Route Patterns

### Static Routes

```crystal
get "/"
get "/users"
get "/api/v1/health"
```

### Dynamic Parameters

```crystal
get "/users/:id"           # Single parameter
get "/posts/:id/comments"  # Parameter in middle
get "/:category/:slug"     # Multiple parameters
```

### Wildcard Routes

```crystal
get "/files/*path"  # Captures rest of path
```

## HTTP Methods

| Method | Macro | Description |
|--------|-------|-------------|
| GET | `get` | Retrieve resource |
| POST | `post` | Create resource |
| PUT | `put` | Replace resource |
| PATCH | `patch` | Update resource |
| DELETE | `delete` | Remove resource |
| OPTIONS | `options` | Get options |
| HEAD | `head` | Get headers only |

## Route Matching

Routes are matched in order of specificity:
1. Exact static matches
2. Parameterized routes
3. Wildcard routes

```crystal
get "/users"          # Matches /users exactly
get "/users/:id"      # Matches /users/123
get "/users/*rest"    # Matches /users/123/posts/456
```

## Accessing Route Parameters

```crystal
get "/users/:id/posts/:post_id"

def call
  user_id = params["id"]        # => "123"
  post_id = params["post_id"]   # => "456"
end
```

### Wildcard Parameters

```crystal
get "/files/*path"

def call
  path = params["path"]  # => "docs/readme.md"
end
```

## Route Constraints

### Custom Constraints

```crystal
# Only match numeric IDs
get "/users/:id" do
  constraint :id, /^\d+$/
end
```

## Router Configuration

### Path Caching

Enable path caching for performance:

```crystal
Azu.configure do |config|
  config.router.path_cache_size = 1000  # Cache 1000 paths
end
```

## Router API

### routes

Get all registered routes.

```crystal
Azu.router.routes.each do |route|
  puts "#{route.method} #{route.path}"
end
```

### find

Find a route for a request.

```crystal
route = Azu.router.find("GET", "/users/123")
route.handler  # => Handler
route.params   # => {"id" => "123"}
```

## Route Groups

Organize routes with common prefixes:

```crystal
# Define multiple endpoints with shared prefix
struct ApiV1::UsersIndex
  include Azu::Endpoint(EmptyRequest, UsersResponse)
  get "/api/v1/users"
end

struct ApiV1::UsersShow
  include Azu::Endpoint(EmptyRequest, UserResponse)
  get "/api/v1/users/:id"
end
```

## Performance

The router uses a radix tree (Radix) for O(k) route matching where k is the path length.

### Benchmarks

- Static routes: ~150ns
- Dynamic routes: ~200ns
- Wildcard routes: ~250ns

### Optimization Tips

1. Put most common routes first in handler chain
2. Enable path caching for repeated paths
3. Use static paths when possible

## Error Handling

### Not Found

When no route matches:

```crystal
# Handler::Rescuer returns 404
{
  "error": "Not Found",
  "path": "/unknown"
}
```

### Method Not Allowed

When path matches but method doesn't:

```crystal
# Returns 405 with Allow header
{
  "error": "Method Not Allowed",
  "allowed": ["GET", "POST"]
}
```

## Complete Example

```crystal
# User CRUD endpoints
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

struct UsersUpdate
  include Azu::Endpoint(UpdateUserRequest, UserResponse)
  put "/users/:id"
end

struct UsersDelete
  include Azu::Endpoint(EmptyRequest, Azu::Response::Empty)
  delete "/users/:id"
end

# Nested routes
struct UserPosts
  include Azu::Endpoint(EmptyRequest, PostsResponse)
  get "/users/:user_id/posts"
end

struct UserPostShow
  include Azu::Endpoint(EmptyRequest, PostResponse)
  get "/users/:user_id/posts/:id"
end
```

## See Also

- [Endpoint Reference](endpoint.md)
- [Handler Reference](../handlers/built-in.md)

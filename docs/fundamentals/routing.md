# Routing

Routing in Azu is built on a high-performance routing tree that provides type-safe, efficient URL handling with support for parameters, constraints, and nested routes.

## What is Routing?

Routing maps HTTP requests to specific endpoints based on:

- **URL Pattern**: The path pattern to match
- **HTTP Method**: The HTTP method (GET, POST, PUT, DELETE, etc.)
- **Endpoint**: The endpoint that handles the request
- **Parameters**: URL parameters extracted from the path

## Basic Routing

### Simple Routes

```crystal
module MyApp
  include Azu

  router do
    # Root route
    root :web, HomeEndpoint

    # Simple routes
    get "/about", AboutEndpoint
    get "/contact", ContactEndpoint
    post "/contact", ContactFormEndpoint
  end
end
```

### Route Groups

Organize related routes:

```crystal
router do
  # Web routes
  routes :web, "/" do
    get "/", HomeEndpoint
    get "/about", AboutEndpoint
    get "/contact", ContactEndpoint
  end

  # API routes
  routes :api, "/api" do
    get "/users", ListUsersEndpoint
    get "/users/:id", ShowUserEndpoint
    post "/users", CreateUserEndpoint
    put "/users/:id", UpdateUserEndpoint
    delete "/users/:id", DeleteUserEndpoint
  end

  # Admin routes
  routes :admin, "/admin" do
    get "/dashboard", AdminDashboardEndpoint
    get "/users", AdminUsersEndpoint
  end
end
```

## HTTP Methods

Azu supports all standard HTTP methods:

```crystal
router do
  # GET - Retrieve data
  get "/users", ListUsersEndpoint
  get "/users/:id", ShowUserEndpoint

  # POST - Create data
  post "/users", CreateUserEndpoint

  # PUT - Update data
  put "/users/:id", UpdateUserEndpoint

  # PATCH - Partial update
  patch "/users/:id", PartialUpdateUserEndpoint

  # DELETE - Delete data
  delete "/users/:id", DeleteUserEndpoint

  # HEAD - Head request
  head "/users", UsersHeadEndpoint

  # OPTIONS - Options request
  options "/users", UsersOptionsEndpoint

  # TRACE - Trace request
  trace "/users", UsersTraceEndpoint
end
```

## Route Parameters

### Path Parameters

Extract parameters from the URL path:

```crystal
router do
  # Single parameter
  get "/users/:id", ShowUserEndpoint

  # Multiple parameters
  get "/users/:user_id/posts/:post_id", ShowUserPostEndpoint

  # Nested parameters
  get "/users/:user_id/posts/:post_id/comments/:comment_id", ShowCommentEndpoint
end
```

### Accessing Parameters

Access parameters in your endpoints:

```crystal
struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request::Empty, UserResponse)

  get "/users/:id"

  def call : UserResponse
    # Access path parameters
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

Handle query string parameters:

```crystal
struct ListUsersEndpoint
  include Azu::Endpoint(Azu::Request::Empty, UsersListResponse)

  get "/users"

  def call : UsersListResponse
    # Access query parameters
    page = params["page"]?.try(&.to_i) || 1
    limit = params["limit"]?.try(&.to_i) || 10
    search = params["search"]?
    sort = params["sort"]? || "created_at"
    order = params["order"]? || "desc"

    users = User.search(search)
      .order_by(sort, order)
      .paginate(page, limit)

    UsersListResponse.new(users)
  end
end
```

## Route Constraints

Add constraints to route parameters:

```crystal
router do
  # Numeric ID constraint
  get "/users/:id", ShowUserEndpoint, constraints: {id: /\d+/}

  # Slug constraint
  get "/posts/:slug", ShowPostEndpoint, constraints: {slug: /[a-z0-9-]+/}

  # Email constraint
  get "/users/:email", FindUserByEmailEndpoint, constraints: {email: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i}
end
```

## Nested Routes

Organize complex route hierarchies:

```crystal
router do
  # User routes
  routes :users, "/users" do
    get "/", ListUsersEndpoint
    get "/:id", ShowUserEndpoint
    post "/", CreateUserEndpoint
    put "/:id", UpdateUserEndpoint
    delete "/:id", DeleteUserEndpoint

    # User posts
    routes :user_posts, "/:user_id/posts" do
      get "/", ListUserPostsEndpoint
      get "/:id", ShowUserPostEndpoint
      post "/", CreateUserPostEndpoint
      put "/:id", UpdateUserPostEndpoint
      delete "/:id", DeleteUserPostEndpoint

      # Post comments
      routes :post_comments, "/:post_id/comments" do
        get "/", ListPostCommentsEndpoint
        get "/:id", ShowPostCommentEndpoint
        post "/", CreatePostCommentEndpoint
        put "/:id", UpdatePostCommentEndpoint
        delete "/:id", DeletePostCommentEndpoint
      end
    end
  end
end
```

## Route Namespaces

Organize routes by namespace:

```crystal
router do
  # Public namespace
  namespace :public do
    get "/", HomeEndpoint
    get "/about", AboutEndpoint
    get "/contact", ContactEndpoint
  end

  # API namespace
  namespace :api do
    get "/users", ListUsersEndpoint
    get "/users/:id", ShowUserEndpoint
    post "/users", CreateUserEndpoint
  end

  # Admin namespace
  namespace :admin do
    get "/dashboard", AdminDashboardEndpoint
    get "/users", AdminUsersEndpoint
    get "/settings", AdminSettingsEndpoint
  end
end
```

## Route Scoping

Apply common settings to groups of routes:

```crystal
router do
  # Web scope
  scope :web, path: "/", constraints: {format: "html"} do
    get "/", HomeEndpoint
    get "/about", AboutEndpoint
    get "/contact", ContactEndpoint
  end

  # API scope
  scope :api, path: "/api", constraints: {format: "json"} do
    get "/users", ListUsersEndpoint
    get "/users/:id", ShowUserEndpoint
    post "/users", CreateUserEndpoint
  end

  # Admin scope
  scope :admin, path: "/admin", constraints: {format: "html"} do
    get "/dashboard", AdminDashboardEndpoint
    get "/users", AdminUsersEndpoint
  end
end
```

## Route Helpers

Generate URLs for your routes:

```crystal
# Define named routes
router do
  get "/users/:id", ShowUserEndpoint, as: :user
  get "/users/:user_id/posts/:id", ShowUserPostEndpoint, as: :user_post
end

# Generate URLs
user_url(123) # => "/users/123"
user_post_url(123, 456) # => "/users/123/posts/456"
```

## Route Testing

Test your routes:

```crystal
require "spec"

describe "User routes" do
  it "routes GET /users to ListUsersEndpoint" do
    route = MyApp.router.find_route("GET", "/users")
    route.endpoint.should eq(ListUsersEndpoint)
  end

  it "routes GET /users/:id to ShowUserEndpoint" do
    route = MyApp.router.find_route("GET", "/users/123")
    route.endpoint.should eq(ShowUserEndpoint)
    route.params["id"].should eq("123")
  end

  it "routes POST /users to CreateUserEndpoint" do
    route = MyApp.router.find_route("POST", "/users")
    route.endpoint.should eq(CreateUserEndpoint)
  end
end
```

## Route Debugging

Debug your routes:

```crystal
# List all routes
MyApp.router.routes.each do |route|
  puts "#{route.method} #{route.path} -> #{route.endpoint}"
end

# Find route for specific path
route = MyApp.router.find_route("GET", "/users/123")
puts "Route: #{route.method} #{route.path}"
puts "Endpoint: #{route.endpoint}"
puts "Parameters: #{route.params}"
```

## Route Performance

Azu's routing is optimized for performance:

### Route Tree

Routes are organized in a tree structure for efficient matching:

```
/
├── users/
│   ├── :id/
│   │   ├── posts/
│   │   │   └── :post_id/
│   │   └── comments/
│   │       └── :comment_id/
│   └── search/
└── posts/
    └── :id/
```

### Matching Algorithm

1. **Method Check**: Verify HTTP method matches
2. **Path Traversal**: Walk the route tree
3. **Parameter Extraction**: Extract parameters from path
4. **Constraint Validation**: Validate parameter constraints
5. **Endpoint Resolution**: Return the matching endpoint

## Route Caching

Cache routes for better performance:

```crystal
module MyApp
  include Azu

  configure do |config|
    # Enable route caching
    config.router.cache_routes = true
    config.router.cache_size = 1000
  end
end
```

## Route Middleware

Apply middleware to specific routes:

```crystal
router do
  # Public routes (no authentication)
  get "/", HomeEndpoint
  get "/about", AboutEndpoint

  # Protected routes (require authentication)
  scope :protected, middleware: [AuthMiddleware.new] do
    get "/dashboard", DashboardEndpoint
    get "/profile", ProfileEndpoint
  end

  # Admin routes (require admin authentication)
  scope :admin, middleware: [AuthMiddleware.new, AdminMiddleware.new] do
    get "/admin/dashboard", AdminDashboardEndpoint
    get "/admin/users", AdminUsersEndpoint
  end
end
```

## Route Validation

Validate routes at compile time:

```crystal
# This will fail at compile time if the endpoint doesn't exist
router do
  get "/users", NonExistentEndpoint  # Compile error!
end
```

## Route Documentation

Document your routes:

```crystal
router do
  # User management
  get "/users", ListUsersEndpoint,
    description: "List all users",
    tags: ["users"]

  get "/users/:id", ShowUserEndpoint,
    description: "Get user by ID",
    tags: ["users"],
    parameters: {
      id: {type: "integer", description: "User ID"}
    }

  post "/users", CreateUserEndpoint,
    description: "Create a new user",
    tags: ["users"],
    request_body: "UserRequest"
end
```

## Best Practices

### 1. Use RESTful Conventions

```crystal
# Good: RESTful routes
get "/users", ListUsersEndpoint
get "/users/:id", ShowUserEndpoint
post "/users", CreateUserEndpoint
put "/users/:id", UpdateUserEndpoint
delete "/users/:id", DeleteUserEndpoint

# Avoid: Non-RESTful routes
get "/get_users", ListUsersEndpoint
post "/create_user", CreateUserEndpoint
```

### 2. Group Related Routes

```crystal
# Good: Grouped routes
routes :users, "/users" do
  get "/", ListUsersEndpoint
  get "/:id", ShowUserEndpoint
  post "/", CreateUserEndpoint
end

# Avoid: Scattered routes
get "/users", ListUsersEndpoint
get "/users/:id", ShowUserEndpoint
post "/users", CreateUserEndpoint
```

### 3. Use Descriptive Route Names

```crystal
# Good: Descriptive names
get "/users/:id", ShowUserEndpoint, as: :user
get "/users/:user_id/posts/:id", ShowUserPostEndpoint, as: :user_post

# Avoid: Generic names
get "/users/:id", ShowUserEndpoint, as: :show
get "/users/:user_id/posts/:id", ShowUserPostEndpoint, as: :show_post
```

### 4. Apply Constraints

```crystal
# Good: Constrained routes
get "/users/:id", ShowUserEndpoint, constraints: {id: /\d+/}
get "/posts/:slug", ShowPostEndpoint, constraints: {slug: /[a-z0-9-]+/}

# Avoid: Unconstrained routes
get "/users/:id", ShowUserEndpoint  # Could match non-numeric IDs
```

### 5. Use Namespaces

```crystal
# Good: Namespaced routes
namespace :api do
  get "/users", ListUsersEndpoint
  get "/users/:id", ShowUserEndpoint
end

# Avoid: Flat routes
get "/api/users", ListUsersEndpoint
get "/api/users/:id", ShowUserEndpoint
```

## Next Steps

Now that you understand routing:

1. **[Endpoints](endpoints.md)** - Use routes in your endpoints
2. **[Middleware](middleware.md)** - Apply middleware to routes
3. **[Testing](../testing.md)** - Test your routes
4. **[API Design](../features/api-design.md)** - Design RESTful APIs
5. **[Performance](../advanced/performance.md)** - Optimize route performance

---

_Routing in Azu provides a powerful, type-safe way to organize your application's URL structure. With support for parameters, constraints, and nested routes, it makes building complex web applications straightforward and maintainable._

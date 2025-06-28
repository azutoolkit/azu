# Endpoints

Endpoints are the fundamental building blocks of Azu applications. They represent individual HTTP routes and encapsulate all the logic needed to handle specific requests. Each endpoint follows a strict contract pattern that ensures type safety, predictable behavior, and maintainable code.

## Philosophy and Design Rationale

Azu's endpoint design is rooted in several core principles that distinguish it from traditional web frameworks:

### 1. Type Safety First

Unlike dynamic frameworks that rely on runtime validation, Azu enforces contracts at compile time. This means:

- **Compile-time guarantees**: Type errors are caught before deployment
- **Self-documenting APIs**: Contracts serve as living documentation
- **Refactoring safety**: Changes are validated across the entire codebase
- **IDE support**: Full autocomplete and error detection

```mermaid
graph LR
    A[Request Contract] --> B[Compile-time Validation]
    B --> C[Type-safe Processing]
    C --> D[Response Contract]
    D --> E[Structured Output]

    subgraph "Benefits"
        B --> F[No Runtime Type Errors]
        C --> G[IDE Autocomplete]
        D --> H[Consistent APIs]
        E --> I[Predictable Behavior]
    end

    style A fill:#e8f5e8
    style D fill:#e3f2fd
    style F fill:#fff3e0
    style G fill:#fff3e0
    style H fill:#fff3e0
    style I fill:#fff3e0
```

### 2. Single Responsibility Principle

Each endpoint handles exactly one concern, avoiding the pitfalls of monolithic controllers:

```crystal
# ✅ Good: Single responsibility
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)
  post "/users"

  def call : UserResponse
    # Only user creation logic
    user = User.create!(create_user_request.to_h)
    UserResponse.new(user)
  end
end

# ❌ Bad: Multiple responsibilities
struct UserController
  # Handles create, read, update, delete, search, etc.
  # Becomes hard to test and maintain
end
```

### 3. Explicit Contracts Over Implicit Behavior

Azu makes all data flow explicit through contracts:

```crystal
# Request contract defines exactly what the endpoint expects
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  # Validation rules are explicit
  validate name, presence: true, length: {min: 2, max: 100}
  validate email, presence: true, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
  validate age, numericality: {greater_than: 0, less_than: 150}, allow_nil: true
end

# Response contract defines exactly what the endpoint returns
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

### 4. Testability by Design

Endpoints are designed to be easily testable in isolation:

```crystal
# Each endpoint can be tested independently
describe CreateUserEndpoint do
  it "creates a user successfully" do
    endpoint = CreateUserEndpoint.new
    request = HTTP::Request.new("POST", "/users",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: {name: "John", email: "john@example.com"}.to_json
    )
    context = HTTP::Server::Context.new(request, HTTP::IO.new(IO::Memory.new))

    response = endpoint.call(context)

    response.status_code.should eq(201)
    JSON.parse(response.body)["name"].should eq("John")
  end
end
```

## Detailed Endpoint Anatomy

Understanding the internal structure of endpoints is crucial for building robust applications.

### Core Components

```mermaid
graph TD
    A[HTTP Request] --> B[Router Resolution]
    B --> C[Endpoint Instance]
    C --> D[Request Contract]
    D --> E[Validation Layer]
    E --> F[Business Logic]
    F --> G[Response Object]
    G --> H[Content Negotiation]
    H --> I[HTTP Response]

    subgraph "Type Safety Layer"
        D --> J[Compile-time Contracts]
        E --> K[Runtime Validation]
        G --> L[Structured Output]
    end

    subgraph "Error Handling"
        E --> M[Validation Errors]
        F --> N[Business Errors]
        G --> O[Response Errors]
    end

    style C fill:#fff3e0
    style D fill:#e8f5e8
    style G fill:#e3f2fd
    style M fill:#ffebee
    style N fill:#ffebee
    style O fill:#ffebee
```

### Endpoint Structure Breakdown

```crystal
struct UserEndpoint
  # 1. Module inclusion - defines the contract
  include Azu::Endpoint(UserRequest, UserResponse)

  # 2. Route definition - maps HTTP method to path
  get "/users/:id"

  # 3. Core handler - implements the business logic
  def call : UserResponse
    # 4. Parameter extraction
    user_id = params["id"].to_i64

    # 5. Request validation
    request = user_request
    unless request.valid?
      raise Azu::Response::ValidationError.new(request.errors)
    end

    # 6. Business logic
    user = User.find(user_id)
    raise Azu::Response::NotFound.new unless user

    # 7. Response creation
    UserResponse.new(user)
  end
end
```

### Instance Variables and State

Each endpoint instance maintains specific state during request processing:

```crystal
module Azu
  module Endpoint(Request, Response)
    # Request context - HTTP server context
    @context : HTTP::Server::Context? = nil

    # Parsed parameters - route, query, and body parameters
    @params : Params(Request)? = nil

    # Request object - lazy-loaded contract instance
    @request_object : Request? = nil
  end
end
```

### Lifecycle Methods

Endpoints provide several lifecycle methods for different stages:

```crystal
struct LifecycleEndpoint
  include Azu::Endpoint(LifecycleRequest, LifecycleResponse)

  get "/lifecycle/:id"

  def call : LifecycleResponse
    # Pre-processing
    before_call

    # Main execution
    result = execute_business_logic

    # Post-processing
    after_call(result)

    LifecycleResponse.new(result)
  end

  private def before_call
    # Setup, logging, metrics
    Log.info("Processing request", {
      user_id: params["id"],
      timestamp: Time.utc
    })
  end

  private def execute_business_logic
    # Core business logic
    user = User.find(params["id"].to_i64)
    user.process_request(lifecycle_request)
  end

  private def after_call(result)
    # Cleanup, notifications
    Metrics.increment("requests.processed")
    notify_analytics(result)
  end
end
```

## Type Safety and Contract Enforcement

Azu's type system provides compile-time guarantees that eliminate entire classes of runtime errors.

### Compile-Time Contract Validation

```mermaid
graph TD
    A[Source Code] --> B[Crystal Compiler]
    B --> C{Type Check}
    C -->|Valid| D[Compiled Binary]
    C -->|Invalid| E[Compilation Error]

    subgraph "Type Checks"
        F[Request Contract Match]
        G[Response Contract Match]
        H[Method Signature Match]
        I[Parameter Type Match]
    end

    C --> F
    C --> G
    C --> H
    C --> I

    style E fill:#ffebee
    style D fill:#e8f5e8
```

### Request Contract Enforcement

Request contracts ensure that endpoints only receive valid, typed data:

```crystal
# Define the contract
struct CreateProductRequest
  include Azu::Request

  getter name : String
  getter price : Float64
  getter category : String
  getter description : String?
  getter tags : Array(String)

  # Validation rules
  validate name, presence: true, length: {min: 3, max: 100}
  validate price, presence: true, numericality: {greater_than: 0}
  validate category, presence: true, inclusion: {in: %w(electronics books clothing)}
  validate description, length: {max: 500}, allow_nil: true
  validate tags, length: {max: 10}
end

# Use in endpoint - compile-time safety
struct CreateProductEndpoint
  include Azu::Endpoint(CreateProductRequest, ProductResponse)

  post "/products"

  def call : ProductResponse
    # Type-safe access to request data
    request = create_product_request

    # Compile-time guarantee: all fields are properly typed
    product = Product.create!(
      name: request.name,           # String
      price: request.price,         # Float64
      category: request.category,   # String
      description: request.description, # String?
      tags: request.tags            # Array(String)
    )

    ProductResponse.new(product)
  end
end
```

### Response Contract Enforcement

Response contracts ensure consistent, structured output:

```crystal
# Define response structure
struct ProductResponse
  include Azu::Response

  def initialize(@product : Product, @include_details : Bool = false)
  end

  def render
    case context.request.headers["Accept"]?
    when .try(&.includes?("application/json"))
      render_json
    when .try(&.includes?("text/html"))
      render_html
    when .try(&.includes?("application/xml"))
      render_xml
    else
      render_json # Default
    end
  end

  private def render_json
    {
      id: @product.id,
      name: @product.name,
      price: @product.price,
      category: @product.category,
      in_stock: @product.quantity > 0,
      created_at: @product.created_at.to_rfc3339
    }.to_json
  end

  private def render_html
    view "products/show.html", {
      product: @product,
      include_details: @include_details
    }
  end

  private def render_xml
    <<-XML
    <?xml version="1.0" encoding="UTF-8"?>
    <product id="#{@product.id}">
      <name>#{@product.name}</name>
      <price>#{@product.price}</price>
      <category>#{@product.category}</category>
      <in_stock>#{@product.quantity > 0}</in_stock>
    </product>
    XML
  end
end
```

### Method Signature Enforcement

The `call` method must return the exact response type:

```crystal
struct StrictEndpoint
  include Azu::Endpoint(StrictRequest, StrictResponse)

  get "/strict/:id"

  def call : StrictResponse
    # ✅ This compiles - correct return type
    return StrictResponse.new(data)

    # ❌ This won't compile - wrong return type
    # return "string"

    # ❌ This won't compile - undefined method
    # return strict_request.invalid_field
  end
end
```

### Generic Type Constraints

Endpoints can work with generic types while maintaining type safety:

```crystal
# Generic response for collections
struct CollectionResponse(T)
  include Azu::Response

  def initialize(@items : Array(T), @total_count : Int32, @page : Int32)
  end

  def render
    {
      items: @items.map(&.to_json),
      pagination: {
        page: @page,
        total_count: @total_count,
        has_next: (@page * 20) < @total_count
      }
    }.to_json
  end
end

# Type-safe collection endpoint
struct UsersIndexEndpoint
  include Azu::Endpoint(UsersIndexRequest, CollectionResponse(User))

  get "/users"

  def call : CollectionResponse(User)
    request = users_index_request
    users = User.all.limit(request.limit).offset(request.offset)
    total = User.count

    CollectionResponse(User).new(users, total, request.page)
  end
end
```

### Compile-Time Error Examples

Azu catches common mistakes at compile time:

```crystal
# ❌ Compilation Error: Wrong response type
struct WrongResponseEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  def call : String  # Should return UserResponse
    "Hello World"
  end
end

# ❌ Compilation Error: Missing required field
struct IncompleteRequest
  include Azu::Request
  getter name : String
  # Missing email field that endpoint expects
end

# ❌ Compilation Error: Undefined method
struct UndefinedMethodEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  def call : UserResponse
    user_request.non_existent_field  # Method doesn't exist
    UserResponse.new(user)
  end
end
```

This type safety ensures that:

- **API contracts are enforced**: Clients and servers agree on data structure
- **Refactoring is safe**: Changes are validated across the entire codebase
- **Runtime errors are minimized**: Type mismatches are caught early
- **Documentation is accurate**: Code serves as living documentation

## Route Registration and Advanced Routing

Azu's routing system is built on the high-performance Radix tree with intelligent caching and advanced features for complex routing scenarios.

### Route Registration Fundamentals

```mermaid
graph LR
    A[Route Definition] --> B[Router Registration]
    B --> C[Radix Tree Insertion]
    C --> D[Route Caching]
    D --> E[Request Matching]

    subgraph "Route Types"
        F[Static Routes]
        G[Dynamic Routes]
        H[Constrained Routes]
        I[Nested Routes]
    end

    A --> F
    A --> G
    A --> H
    A --> I

    subgraph "Performance"
        J[O_log_n Lookup]
        K[LRU Cache]
        L[Zero Allocation]
    end

    E --> J
    E --> K
    E --> L

    style E fill:#e8f5e8
    style J fill:#fff3e0
    style K fill:#fff3e0
    style L fill:#fff3e0

```

### Basic Route Registration

Routes are defined directly on endpoints using HTTP method macros:

```crystal
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  # Standard HTTP methods
  get "/users"                    # GET /users
  post "/users"                   # POST /users
  get "/users/:id"                # GET /users/123
  put "/users/:id"                # PUT /users/123
  patch "/users/:id"              # PATCH /users/123
  delete "/users/:id"             # DELETE /users/123
  head "/users/:id"               # HEAD /users/123
  options "/users"                # OPTIONS /users

  def call : UserResponse
    # Route handling logic
    handle_user_request
  end
end
```

### Dynamic Route Parameters

Dynamic segments capture values from the URL path:

```crystal
struct ComplexEndpoint
  include Azu::Endpoint(ComplexRequest, ComplexResponse)

  # Single parameter
  get "/users/:id"

  # Multiple parameters
  get "/users/:user_id/posts/:post_id"

  # Nested resources
  get "/organizations/:org_id/teams/:team_id/members/:member_id"

  # Optional parameters (using query strings)
  get "/search"  # ?q=term&page=1&limit=10

  def call : ComplexResponse
    case context.request.path
    when .starts_with?("/users/") && params["user_id"]? && params["post_id"]?
      # Handle /users/:user_id/posts/:post_id
      user_id = params["user_id"].to_i64
      post_id = params["post_id"].to_i64
      handle_user_post(user_id, post_id)

    when .starts_with?("/organizations/")
      # Handle nested organization routes
      org_id = params["org_id"].to_i64
      team_id = params["team_id"].to_i64
      member_id = params["member_id"].to_i64
      handle_organization_member(org_id, team_id, member_id)

    when .starts_with?("/search")
      # Handle search with query parameters
      handle_search

    else
      # Handle simple user routes
      user_id = params["id"].to_i64
      handle_user(user_id)
    end
  end

  private def handle_user_post(user_id : Int64, post_id : Int64) : ComplexResponse
    user = User.find(user_id)
    post = user.posts.find(post_id)
    ComplexResponse.new(user: user, post: post)
  end

  private def handle_organization_member(org_id : Int64, team_id : Int64, member_id : Int64) : ComplexResponse
    org = Organization.find(org_id)
    team = org.teams.find(team_id)
    member = team.members.find(member_id)
    ComplexResponse.new(organization: org, team: team, member: member)
  end

  private def handle_search : ComplexResponse
    request = complex_request
    results = SearchService.search(
      query: request.query,
      page: request.page || 1,
      limit: request.limit || 20
    )
    ComplexResponse.new(search_results: results)
  end
end
```

### Route Constraints

Add constraints to route parameters for validation and security:

```crystal
struct ConstrainedEndpoint
  include Azu::Endpoint(ConstrainedRequest, ConstrainedResponse)

  # Numeric ID constraint
  get "/users/:id" do |route|
    route.constraints(id: /\d+/)
  end

  # UUID constraint
  get "/documents/:uuid" do |route|
    route.constraints(uuid: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)
  end

  # File extension constraint
  get "/files/:name.:ext" do |route|
    route.constraints(ext: /jpg|png|gif|pdf/)
  end

  # Custom constraint with validation
  get "/products/:slug" do |route|
    route.constraints(slug: /[a-z0-9-]+/)  # Only lowercase, numbers, hyphens
  end

  # Multiple constraints
  get "/api/v:version/:resource/:id" do |route|
    route.constraints(
      version: /\d+\.\d+/,           # Version format: 1.0, 2.1, etc.
      resource: /users|posts|comments/,  # Allowed resources
      id: /\d+/                      # Numeric ID
    )
  end

  def call : ConstrainedResponse
    # Constraints ensure parameters are valid before reaching business logic
    case context.request.path
    when .starts_with?("/users/")
      user_id = params["id"].to_i64  # Guaranteed to be numeric
      handle_user(user_id)

    when .starts_with?("/documents/")
      uuid = params["uuid"]  # Guaranteed to be valid UUID
      handle_document(uuid)

    when .starts_with?("/files/")
      filename = params["name"]
      extension = params["ext"]  # Guaranteed to be valid extension
      handle_file(filename, extension)

    when .starts_with?("/products/")
      slug = params["slug"]  # Guaranteed to be valid slug
      handle_product(slug)

    when .starts_with?("/api/")
      version = params["version"]  # Guaranteed to be valid version
      resource = params["resource"]  # Guaranteed to be valid resource
      id = params["id"].to_i64  # Guaranteed to be numeric
      handle_api_request(version, resource, id)
    end
  end
end
```

### Route Helpers and URL Generation

Azu automatically generates route helper methods for URL generation:

```crystal
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  get "/users/:id"
  get "/users/:id/posts/:post_id"
  get "/users/:id/profile"

  def call : UserResponse
    # Route helpers are automatically generated
    user_path = UserEndpoint.path(id: 123)                    # "/users/123"
    user_post_path = UserEndpoint.path(id: 123, post_id: 456) # "/users/123/posts/456"
    user_profile_path = UserEndpoint.path(id: 123)            # "/users/123/profile"

    # Use in redirects
    redirect(UserEndpoint.path(id: user.id))

    # Use in templates
    UserResponse.new(user)
  end
end

# In templates, route helpers are available as filters
# {{ user_path(id: user.id) }} -> "/users/123"
# {{ user_post_path(id: user.id, post_id: post.id) }} -> "/users/123/posts/456"
```

### Advanced Routing Patterns

#### Resource-Based Routing

```crystal
struct ResourceEndpoint
  include Azu::Endpoint(ResourceRequest, ResourceResponse)

  # Standard RESTful routes
  get "/articles"                    # Index
  post "/articles"                   # Create
  get "/articles/:id"                # Show
  put "/articles/:id"                # Update
  patch "/articles/:id"              # Partial update
  delete "/articles/:id"             # Destroy

  # Custom actions
  post "/articles/:id/publish"       # Publish action
  post "/articles/:id/unpublish"     # Unpublish action
  post "/articles/:id/duplicate"     # Duplicate action

  # Nested resources
  get "/articles/:id/comments"       # Article comments
  post "/articles/:id/comments"      # Create comment
  delete "/articles/:id/comments/:comment_id" # Delete comment

  def call : ResourceResponse
    case context.request.path
    when .ends_with?("/publish")
      handle_publish_action
    when .ends_with?("/unpublish")
      handle_unpublish_action
    when .ends_with?("/duplicate")
      handle_duplicate_action
    when .includes?("/comments")
      handle_comments
    else
      handle_standard_resource_action
    end
  end

  private def handle_publish_action : ResourceResponse
    article = Article.find(params["id"].to_i64)
    article.publish!
    ResourceResponse.new(article, action: "published")
  end

  private def handle_unpublish_action : ResourceResponse
    article = Article.find(params["id"].to_i64)
    article.unpublish!
    ResourceResponse.new(article, action: "unpublished")
  end

  private def handle_duplicate_action : ResourceResponse
    original = Article.find(params["id"].to_i64)
    duplicated = original.duplicate
    ResourceResponse.new(duplicated, action: "duplicated")
  end

  private def handle_comments : ResourceResponse
    article = Article.find(params["id"].to_i64)

    if params["comment_id"]?
      # Delete specific comment
      comment = article.comments.find(params["comment_id"].to_i64)
      comment.destroy
      ResourceResponse.new(article, action: "comment_deleted")
    else
      # List or create comments
      case method
      when .get?
        comments = article.comments
        ResourceResponse.new(article, comments: comments)
      when .post?
        comment = article.comments.create!(resource_request.to_h)
        ResourceResponse.new(article, comment: comment)
      end
    end
  end
end
```

#### API Versioning

```crystal
struct VersionedEndpoint
  include Azu::Endpoint(VersionedRequest, VersionedResponse)

  # Version-specific routes
  get "/api/v1/users/:id"
  get "/api/v2/users/:id"
  get "/api/v3/users/:id"

  def call : VersionedResponse
    version = extract_api_version
    user_id = params["id"].to_i64

    case version
    when "v1"
      handle_v1_request(user_id)
    when "v2"
      handle_v2_request(user_id)
    when "v3"
      handle_v3_request(user_id)
    else
      raise Azu::Response::BadRequest.new("Unsupported API version")
    end
  end

  private def extract_api_version : String
    # Extract version from path
    path = context.request.path
    if match = path.match(/\/api\/(v\d+)\//)
      match[1]
    else
      "v1" # Default version
    end
  end

  private def handle_v1_request(user_id : Int64) : VersionedResponse
    # Legacy API format
    user = User.find(user_id)
    VersionedResponse.new(
      user: user,
      format: "legacy",
      deprecated: true
    )
  end

  private def handle_v2_request(user_id : Int64) : VersionedResponse
    # Current API format
    user = User.find(user_id)
    VersionedResponse.new(
      user: user,
      format: "current",
      deprecated: false
    )
  end

  private def handle_v3_request(user_id : Int64) : VersionedResponse
    # Future API format with additional data
    user = User.find(user_id)
    VersionedResponse.new(
      user: user,
      format: "future",
      deprecated: false,
      metadata: {
        "schema_version" => "3.0",
        "features" => ["enhanced_profile", "social_links"]
      }
    )
  end
end
```

### Performance Characteristics

Azu's router is optimized for high-performance applications:

```crystal
# Route resolution performance metrics
module Azu
  class Router
    # LRU cache for frequently accessed routes
    @route_cache = LRUCache(String, Route).new(capacity: 1000)

    # Radix tree for O(log n) lookup
    @radix_tree = Radix::Tree(Route).new

    def find_route(method : String, path : String) : Route?
      cache_key = "#{method}:#{path}"

      # Check cache first (O(1))
      if cached_route = @route_cache[cache_key]?
        return cached_route
      end

      # Perform radix tree lookup (O(log n))
      route = @radix_tree.find(path, method)

      # Cache for future requests
      @route_cache[cache_key] = route if route

      route
    end
  end
end

# Performance benchmarks
# - Route resolution: ~0.1ms for cached routes
# - Cache hit ratio: >95% in typical applications
# - Memory usage: Constant with LRU eviction
# - Concurrent access: Lock-free for read operations
```

## Full Request Lifecycle

The request lifecycle in Azu is a comprehensive journey from HTTP request to response, involving multiple layers of processing, validation, and error handling.

### Complete Lifecycle Overview

```mermaid
graph TD
    A[HTTP Request] --> B[Server Reception]
    B --> C[Middleware Stack]
    C --> D[Router Resolution]
    D --> E[Endpoint Instantiation]
    E --> F[Request Parsing]
    F --> G[Contract Creation]
    G --> H[Validation]
    H --> I[Business Logic]
    I --> J[Response Creation]
    J --> K[Content Negotiation]
    K --> L[Response Rendering]
    L --> M[Middleware Stack]
    M --> N[HTTP Response]

    subgraph "Error Handling Paths"
        H --> H1[Validation Error]
        I --> I1[Business Error]
        J --> J1[Response Error]
        H1 --> O[Error Response]
        I1 --> O
        J1 --> O
    end

    subgraph "Middleware Integration"
        C --> C1[Authentication]
        C --> C2[Logging]
        C --> C3[CORS]
        M --> M1[Headers]
        M --> M2[Compression]
    end

    subgraph "Performance Points"
        D --> D1[Route Cache]
        F --> F1[Parameter Parsing]
        K --> K1[Format Selection]
    end

    style E fill:#fff3e0
    style G fill:#e8f5e8
    style J fill:#e3f2fd
    style O fill:#ffebee
```

### Detailed Lifecycle Stages

#### 1. HTTP Request Reception

```crystal
# Raw HTTP request received by server
GET /users/123?include=posts HTTP/1.1
Host: api.example.com
Accept: application/json
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
Content-Type: application/json
User-Agent: Mozilla/5.0 (compatible; MyApp/1.0)
X-Request-ID: req_123456789
```

#### 2. Middleware Stack Processing

```crystal
# Middleware processes request in order
ExampleApp.start [
  Azu::Handler::Rescuer.new,           # Error handling
  Azu::Handler::Logger.new,            # Request logging
  Azu::Handler::CORS.new,              # CORS headers
  Azu::Handler::Authentication.new,    # JWT validation
  Azu::Handler::RateLimit.new,         # Rate limiting
  Azu::Handler::Compression.new,       # Response compression
  Azu::Handler::Security.new,          # Security headers
  # ... more middleware
]

# Each middleware can modify the request context
class CustomMiddleware
  include HTTP::Handler

  def call(context)
    # Pre-processing
    start_time = Time.utc
    request_id = generate_request_id
    context.set("request_id", request_id)
    context.set("start_time", start_time)

    # Add request tracking
    Log.info("Request started", {
      request_id: request_id,
      method: context.request.method,
      path: context.request.path,
      ip: context.request.remote_address.try(&.address)
    })

    # Call next middleware/endpoint
    call_next(context)

    # Post-processing
    duration = Time.utc - start_time
    Log.info("Request completed", {
      request_id: request_id,
      duration: duration.total_milliseconds,
      status: context.response.status_code
    })
  end
end
```

#### 3. Router Resolution

```crystal
# Radix tree finds matching route
router = Azu::CONFIG.router

# Route resolution process
route = router.find_route("GET", "/users/123")
# Returns: UserShowEndpoint with params: {"id" => "123"}

# Route caching for performance
cache_key = "GET:/users/123"
if cached_route = route_cache[cache_key]?
  route = cached_route  # O(1) cache hit
else
  route = radix_tree.find("/users/123", "GET")  # O(log n) tree lookup
  route_cache[cache_key] = route  # Cache for future requests
end
```

#### 4. Endpoint Instantiation

```crystal
# Framework creates endpoint instance
endpoint = UserShowEndpoint.new

# Instance variables initialized
endpoint.instance_variable_set(:@context, context)
endpoint.instance_variable_set(:@params, Params(UserShowRequest).new(context.request))
endpoint.instance_variable_set(:@request_object, nil)  # Lazy-loaded

# Endpoint is now ready to handle the request
```

#### 5. Request Parsing and Contract Creation

```crystal
# Parameters extracted from multiple sources
params = {
  # Route parameters
  "id" => "123",

  # Query parameters
  "include" => "posts,comments",
  "page" => "1",
  "limit" => "20",

  # Headers (if applicable)
  "authorization" => "Bearer token123",

  # Body (for POST/PUT requests)
  "name" => "John Doe",
  "email" => "john@example.com"
}

# Request contract instantiated based on content type
request = case context.request.headers["Content-Type"]?
when .try(&.includes?("application/json"))
  UserShowRequest.from_json(context.request.body.try(&.gets_to_end) || "{}")
when .try(&.includes?("application/x-www-form-urlencoded"))
  UserShowRequest.from_query(params)
else
  UserShowRequest.from_query(params)  # Default to query params
end
```

#### 6. Validation Execution

```crystal
# Schema validation runs automatically
unless request.valid?
  # Collect all validation errors
  errors = request.errors.group_by(&.field).transform_values(&.map(&.message))

  # Raise validation error with proper HTTP status
  raise Azu::Response::ValidationError.new(errors)
end

# Custom validation (if defined)
begin
  request.validate!
rescue ex : ValidationError
  raise Azu::Response::ValidationError.new(ex.errors)
end

# Example validation errors
{
  "email" => ["is required", "must be a valid email address"],
  "password" => ["must be at least 8 characters"],
  "age" => ["must be a positive integer"]
}
```

#### 7. Business Logic Execution

```crystal
def call : UserShowResponse
  # Authorization check
  current_user = context.get("current_user")
  user_id = params["id"].to_i64

  unless current_user.can_view_user?(user_id)
    raise Azu::Response::AuthorizationError.new(
      "Cannot view user #{user_id}"
    )
  end

  # Database query with error handling
  user = begin
    User.find(user_id)
  rescue ex : RecordNotFound
    raise Azu::Response::NotFound.new("/users/#{user_id}")
  end

  # Business logic execution
  user.increment_view_count!

  # Background processing
  spawn do
    notify_analytics(user, current_user)
    update_user_statistics(user)
  end

  # Response creation with conditional data
  include_posts = request.include_posts?
  include_comments = request.include_comments?

  UserShowResponse.new(
    user: user,
    include_posts: include_posts,
    include_comments: include_comments
  )
end
```

#### 8. Response Creation and Rendering

```crystal
# Response object created
response = UserShowResponse.new(user, include_posts: true, include_comments: false)

# Content negotiation based on Accept header
def render
  accept_header = context.request.headers["Accept"]?

  case accept_header
  when .try(&.includes?("application/json"))
    render_json
  when .try(&.includes?("text/html"))
    render_html
  when .try(&.includes?("application/xml"))
    render_xml
  when .try(&.includes?("text/plain"))
    render_text
  else
    render_json  # Default to JSON
  end
end

# Response rendering with proper content type
private def render_json
  context.response.content_type = "application/json"
  {
    id: @user.id,
    name: @user.name,
    email: @user.email,
    posts: @include_posts ? @user.posts.map(&.to_json) : nil,
    comments: @include_comments ? @user.comments.map(&.to_json) : nil,
    created_at: @user.created_at.to_rfc3339,
    updated_at: @user.updated_at.to_rfc3339
  }.to_json
end

private def render_html
  context.response.content_type = "text/html"
  view "users/show.html", {
    user: @user,
    include_posts: @include_posts,
    include_comments: @include_comments
  }
end
```

### Error Handling Throughout the Lifecycle

```mermaid
graph TD
    A[Request] --> B{Validation}
    B -->|Pass| C{Authorization}
    B -->|Fail| D[ValidationError 400]
    C -->|Pass| E{Business Logic}
    C -->|Fail| F[AuthorizationError 403]
    E -->|Pass| G{Response Creation}
    E -->|Fail| H[BusinessError 422]
    E -->|Exception| I[SystemError 500]
    G -->|Pass| J[Success Response]
    G -->|Fail| K[ResponseError 500]

    D --> L[Error Response]
    F --> L
    H --> L
    I --> L
    K --> L

    L --> M[Middleware Stack]
    M --> N[HTTP Response]

    style D fill:#ffebee
    style F fill:#ffebee
    style H fill:#ffebee
    style I fill:#ffebee
    style K fill:#ffebee
    style J fill:#e8f5e8
```

### Performance Optimization Points

#### 1. Route Caching

```crystal
# LRU cache for frequently accessed routes
@route_cache = LRUCache(String, Route).new(capacity: 1000)

# Cache hit provides O(1) lookup
if cached_route = @route_cache[cache_key]?
  return cached_route
end
```

#### 2. Parameter Parsing Optimization

```crystal
# Efficient parameter access with caching
def call : UserResponse
  # Cache parameter conversion
  user_id = @user_id ||= params["id"].to_i64

  # Use efficient database queries
  user = User.find(user_id, select: "id, name, email")

  UserResponse.new(user)
end
```

#### 3. Background Processing

```crystal
# Non-blocking background tasks
def call : UserResponse
  user = User.find(params["id"].to_i64)

  # Spawn background processing
  spawn do
    user.increment_view_count!
    notify_analytics(user)
    update_search_index(user)
  end

  # Return immediately
  UserResponse.new(user)
end
```

#### 4. Response Streaming

```crystal
# Stream large responses
def call : StreamingResponse
  context.response.content_type = "text/event-stream"
  context.response.headers["Cache-Control"] = "no-cache"

  spawn do
    stream_large_dataset(context.response)
  end

  StreamingResponse.new
end

private def stream_large_dataset(response)
  User.all.each_slice(100) do |users|
    response << "data: #{users.to_json}\n\n"
    Fiber.yield  # Allow other fibers to run
  end
end
```

This comprehensive lifecycle ensures that every request is processed consistently, safely, and efficiently, with proper error handling and performance optimizations at each stage.

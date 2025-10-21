# Middleware

Middleware in Azu provides a powerful way to customize request processing. It allows you to add cross-cutting concerns like logging, authentication, CORS, and error handling to your application.

## What is Middleware?

Middleware is a chain of components that process HTTP requests and responses. Each middleware can:

- **Pre-process Requests**: Modify requests before they reach your endpoints
- **Post-process Responses**: Modify responses before they're sent to clients
- **Handle Errors**: Catch and handle errors gracefully
- **Add Functionality**: Add features like logging, authentication, caching

## Middleware Chain

```mermaid
graph LR
    A[Request] --> B[RequestId]
    B --> C[Logger]
    C --> D[CORS]
    D --> E[Static Files]
    E --> F[Endpoint]
    F --> G[Response]

    style A fill:#e1f5fe
    style G fill:#e8f5e8
```

## Built-in Middleware

Azu includes several built-in middleware components:

### RequestId Middleware

Adds unique request identifiers:

```crystal
# Add to middleware chain
Azu::Handler::RequestId.new

# Access request ID in endpoints
request_id = context.request.headers["X-Request-ID"]
```

### Logger Middleware

Logs requests and responses:

```crystal
# Add to middleware chain
Azu::Handler::Logger.new

# Configure logging level
Azu::Handler::Logger.new(level: Log::Severity::INFO)
```

### CORS Middleware

Handles Cross-Origin Resource Sharing:

```crystal
# Basic CORS
Azu::Handler::CORS.new

# Configured CORS
Azu::Handler::CORS.new(
  origins: ["https://example.com", "https://app.example.com"],
  methods: ["GET", "POST", "PUT", "DELETE"],
  headers: ["Content-Type", "Authorization"],
  credentials: true
)
```

### Static Files Middleware

Serves static files:

```crystal
# Serve files from public directory
Azu::Handler::Static.new("public")

# Serve files with custom options
Azu::Handler::Static.new(
  "public",
  index: "index.html",
  headers: {"Cache-Control" => "public, max-age=3600"}
)
```

### Rescuer Middleware

Handles errors gracefully:

```crystal
# Basic error handling
Azu::Handler::Rescuer.new

# Custom error handling
Azu::Handler::Rescuer.new do |error, context|
  Log.error(exception: error) { "Unhandled error in #{context.request.path}" }

  # Return custom error response
  context.response.status_code = 500
  context.response.headers["Content-Type"] = "application/json"
  context.response << {
    error: "Internal Server Error",
    message: "Something went wrong",
    timestamp: Time.utc.to_rfc3339
  }.to_json
end
```

## Custom Middleware

Create custom middleware for your specific needs:

### Basic Middleware

```crystal
class CustomMiddleware
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    # Pre-processing
    Log.info { "Processing request: #{context.request.path}" }

    # Call next middleware
    call_next(context)

    # Post-processing
    Log.info { "Request completed: #{context.response.status_code}" }
  end
end
```

### Authentication Middleware

```crystal
class AuthMiddleware
  include HTTP::Handler

  def initialize(@secret_key : String)
  end

  def call(context : HTTP::Server::Context)
    # Check for authentication token
    token = context.request.headers["Authorization"]?

    if token && valid_token?(token)
      # Extract user from token
      user = decode_token(token)
      context.set("current_user", user)
      call_next(context)
    else
      # Return unauthorized
      context.response.status_code = 401
      context.response.headers["Content-Type"] = "application/json"
      context.response << {
        error: "Unauthorized",
        message: "Authentication required"
      }.to_json
    end
  end

  private def valid_token?(token : String) : Bool
    # Implement token validation
    token.starts_with?("Bearer ") && token.size > 7
  end

  private def decode_token(token : String)
    # Implement token decoding
    # Return user object
  end
end
```

### Rate Limiting Middleware

```crystal
class RateLimitMiddleware
  include HTTP::Handler

  def initialize(@requests_per_minute : Int32 = 60)
    @requests = {} of String => Array(Time)
  end

  def call(context : HTTP::Server::Context)
    client_ip = get_client_ip(context)
    now = Time.utc

    # Clean old requests
    @requests[client_ip] = @requests[client_ip]?.select { |time| now - time < 1.minute } || [] of Time

    # Check rate limit
    if @requests[client_ip].size >= @requests_per_minute
      context.response.status_code = 429
      context.response.headers["Content-Type"] = "application/json"
      context.response.headers["Retry-After"] = "60"
      context.response << {
        error: "Too Many Requests",
        message: "Rate limit exceeded"
      }.to_json
      return
    end

    # Record request
    @requests[client_ip] << now

    call_next(context)
  end

  private def get_client_ip(context : HTTP::Server::Context) : String
    context.request.headers["X-Forwarded-For"]? ||
    context.request.headers["X-Real-IP"]? ||
    context.request.remote_address.try(&.to_s) ||
    "unknown"
  end
end
```

### Caching Middleware

```crystal
class CacheMiddleware
  include HTTP::Handler

  def initialize(@cache_duration : Time::Span = 1.hour)
    @cache = {} of String => {response: String, expires: Time}
  end

  def call(context : HTTP::Server::Context)
    cache_key = generate_cache_key(context)

    # Check cache
    if cached = @cache[cache_key]?
      if cached[:expires] > Time.utc
        # Return cached response
        context.response.status_code = 200
        context.response.headers["Content-Type"] = "application/json"
        context.response.headers["X-Cache"] = "HIT"
        context.response << cached[:response]
        return
      else
        # Remove expired cache
        @cache.delete(cache_key)
      end
    end

    # Process request
    call_next(context)

    # Cache response if successful
    if context.response.status_code == 200
      @cache[cache_key] = {
        response: context.response.body,
        expires: Time.utc + @cache_duration
      }
      context.response.headers["X-Cache"] = "MISS"
    end
  end

  private def generate_cache_key(context : HTTP::Server::Context) : String
    "#{context.request.method}:#{context.request.path}:#{context.request.query_string}"
  end
end
```

## Middleware Configuration

Configure middleware in your application:

```crystal
module MyApp
  include Azu

  configure do |config|
    # Middleware configuration
    config.middleware = [
      Azu::Handler::RequestId.new,
      Azu::Handler::Logger.new,
      Azu::Handler::CORS.new,
      Azu::Handler::Static.new("public"),
      AuthMiddleware.new,
      RateLimitMiddleware.new(100),
      CacheMiddleware.new(1.hour)
    ]
  end
end
```

## Conditional Middleware

Apply middleware conditionally:

```crystal
class ConditionalMiddleware
  include HTTP::Handler

  def initialize(@condition : Proc(HTTP::Server::Context, Bool))
  end

  def call(context : HTTP::Server::Context)
    if @condition.call(context)
      # Apply middleware logic
      process_request(context)
    end

    call_next(context)
  end

  private def process_request(context : HTTP::Server::Context)
    # Middleware logic
  end
end

# Usage
ConditionalMiddleware.new do |context|
  context.request.path.starts_with?("/api/")
end
```

## Middleware Ordering

Order middleware carefully:

```crystal
# Correct order
middleware = [
  Azu::Handler::RequestId.new,      # 1. Add request ID
  Azu::Handler::Logger.new,        # 2. Log requests
  Azu::Handler::CORS.new,          # 3. Handle CORS
  AuthMiddleware.new,              # 4. Authenticate
  RateLimitMiddleware.new,         # 5. Rate limit
  Azu::Handler::Static.new("public"), # 6. Serve static files
  Azu::Handler::Rescuer.new        # 7. Handle errors
]
```

## Error Handling Middleware

Handle specific errors:

```crystal
class ErrorHandlerMiddleware
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    call_next(context)
  rescue e : ValidationError
    handle_validation_error(context, e)
  rescue e : NotFoundError
    handle_not_found_error(context, e)
  rescue e : UnauthorizedError
    handle_unauthorized_error(context, e)
  rescue e
    handle_generic_error(context, e)
  end

  private def handle_validation_error(context, error)
    context.response.status_code = 422
    context.response.headers["Content-Type"] = "application/json"
    context.response << {
      error: "Validation Error",
      message: error.message,
      field_errors: error.field_errors
    }.to_json
  end

  private def handle_not_found_error(context, error)
    context.response.status_code = 404
    context.response.headers["Content-Type"] = "application/json"
    context.response << {
      error: "Not Found",
      message: error.message
    }.to_json
  end

  private def handle_unauthorized_error(context, error)
    context.response.status_code = 401
    context.response.headers["Content-Type"] = "application/json"
    context.response << {
      error: "Unauthorized",
      message: error.message
    }.to_json
  end

  private def handle_generic_error(context, error)
    Log.error(exception: error) { "Unhandled error" }
    context.response.status_code = 500
    context.response.headers["Content-Type"] = "application/json"
    context.response << {
      error: "Internal Server Error",
      message: "Something went wrong"
    }.to_json
  end
end
```

## Testing Middleware

Test your middleware:

```crystal
require "spec"

describe AuthMiddleware do
  it "allows authenticated requests" do
    middleware = AuthMiddleware.new("secret")
    context = create_test_context(
      headers: {"Authorization" => "Bearer valid_token"}
    )

    middleware.call(context)

    context.response.status_code.should eq(200)
  end

  it "rejects unauthenticated requests" do
    middleware = AuthMiddleware.new("secret")
    context = create_test_context

    middleware.call(context)

    context.response.status_code.should eq(401)
  end
end
```

## Best Practices

### 1. Keep Middleware Simple

```crystal
# Good: Simple, focused middleware
class LoggingMiddleware
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    Log.info { "Request: #{context.request.method} #{context.request.path}" }
    call_next(context)
    Log.info { "Response: #{context.response.status_code}" }
  end
end

# Avoid: Complex middleware with multiple responsibilities
class ComplexMiddleware
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    # Logging
    Log.info { "Request: #{context.request.method} #{context.request.path}" }

    # Authentication
    if !authenticated?(context)
      return unauthorized_response(context)
    end

    # Rate limiting
    if rate_limited?(context)
      return rate_limit_response(context)
    end

    # Caching
    if cached_response = get_cached_response(context)
      return cached_response
    end

    # Too many responsibilities!
  end
end
```

### 2. Use Composition

```crystal
# Good: Compose simple middleware
middleware = [
  LoggingMiddleware.new,
  AuthMiddleware.new,
  RateLimitMiddleware.new,
  CacheMiddleware.new
]

# Avoid: Monolithic middleware
class MonolithicMiddleware
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    # All functionality in one place
  end
end
```

### 3. Handle Errors Gracefully

```crystal
class SafeMiddleware
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    begin
      process_request(context)
      call_next(context)
    rescue e
      Log.error(exception: e) { "Middleware error" }
      handle_error(context, e)
    end
  end

  private def handle_error(context, error)
    # Handle error gracefully
  end
end
```

### 4. Use Configuration

```crystal
class ConfigurableMiddleware
  include HTTP::Handler

  def initialize(@config : MiddlewareConfig)
  end

  def call(context : HTTP::Server::Context)
    if @config.enabled?
      process_request(context)
    end

    call_next(context)
  end
end
```

### 5. Test Thoroughly

```crystal
describe "Middleware" do
  it "processes requests correctly" do
    middleware = MyMiddleware.new
    context = create_test_context

    middleware.call(context)

    # Assert expected behavior
  end

  it "handles errors gracefully" do
    middleware = MyMiddleware.new
    context = create_error_context

    middleware.call(context)

    # Assert error handling
  end
end
```

## Performance Considerations

### 1. Minimize Processing

```crystal
class EfficientMiddleware
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    # Only process if necessary
    if should_process?(context)
      process_request(context)
    end

    call_next(context)
  end

  private def should_process?(context) : Bool
    # Quick check to avoid unnecessary processing
    context.request.path.starts_with?("/api/")
  end
end
```

### 2. Use Caching

```crystal
class CachedMiddleware
  include HTTP::Handler

  def initialize
    @cache = {} of String => String
  end

  def call(context : HTTP::Server::Context)
    cache_key = generate_cache_key(context)

    if cached = @cache[cache_key]?
      # Use cached result
      return cached
    end

    # Process and cache
    result = process_request(context)
    @cache[cache_key] = result
    result
  end
end
```

### 3. Avoid Blocking Operations

```crystal
class AsyncMiddleware
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    # Use async operations
    spawn process_async(context)

    call_next(context)
  end

  private def process_async(context)
    # Async processing
  end
end
```

## Next Steps

Now that you understand middleware:

1. **[Endpoints](endpoints.md)** - Use middleware with your endpoints
2. **[Authentication](../features/authentication.md)** - Implement authentication middleware
3. **[Caching](../features/caching.md)** - Add caching middleware
4. **[Testing](../testing.md)** - Test your middleware
5. **[Performance](../advanced/performance.md)** - Optimize middleware performance

---

_Middleware in Azu provides a powerful way to add cross-cutting concerns to your application. With proper design and testing, it makes your code more maintainable and your application more robust._

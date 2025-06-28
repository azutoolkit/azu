# Custom Middleware

Azu allows you to implement custom middleware handlers to extend or modify the request/response lifecycle. This enables you to add application-specific functionality, integrate with external services, and implement custom business logic.

## Overview

Custom middleware enables:

- **Authentication & Authorization**: Custom user authentication and role-based access control
- **Request/Response Transformation**: Modify requests or responses before/after processing
- **Logging & Metrics**: Custom logging, monitoring, and analytics integration
- **External Service Integration**: API rate limiting, caching, and service mesh integration
- **Business Logic**: Application-specific validation, enrichment, and processing

## Middleware Interface

All custom middleware must implement the `Azu::Handler` interface:

```crystal
module Azu::Handler
  abstract def call(request : HttpRequest, response : Response) : Response
end
```

## Basic Implementation

### Simple Middleware

```crystal
class SimpleMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler)
  end

  def call(request : HttpRequest, response : Response) : Response
    # Pre-processing logic
    Log.info { "Processing request: #{request.path}" }

    # Call the next handler in the chain
    result = @next.call(request, response)

    # Post-processing logic
    Log.info { "Request completed: #{request.path}" }

    result
  end
end
```

### Middleware with Configuration

```crystal
class ConfigurableMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @config : Config)
  end

  def call(request : HttpRequest, response : Response) : Response
    # Use configuration
    if @config.enabled && should_process?(request)
      process_request(request, response)
    end

    @next.call(request, response)
  end

  private def should_process?(request : HttpRequest) : Bool
    @config.paths.includes?(request.path)
  end

  private def process_request(request : HttpRequest, response : Response) : Nil
    # Custom processing logic
  end

  struct Config
    property enabled : Bool = true
    property paths : Array(String) = [] of String
  end
end
```

## Common Patterns

### Authentication Middleware

```crystal
class AuthenticationMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @auth_service : AuthService)
  end

  def call(request : HttpRequest, response : Response) : Response
    token = extract_token(request)

    if token && user = @auth_service.authenticate(token)
      # Set user context
      request.set_context(:current_user, user)
      @next.call(request, response)
    else
      # Return unauthorized response
      Response.new(
        status: 401,
        body: {error: "Unauthorized"}.to_json,
        headers: {"Content-Type" => "application/json"}
      )
    end
  end

  private def extract_token(request : HttpRequest) : String?
    request.headers["Authorization"]?.try(&.gsub("Bearer ", ""))
  end
end
```

### Authorization Middleware

```crystal
class AuthorizationMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @required_roles : Array(String))
  end

  def call(request : HttpRequest, response : Response) : Response
    user = request.context(:current_user)?.try(&.as(User))

    if user && has_required_roles?(user)
      @next.call(request, response)
    else
      Response.new(
        status: 403,
        body: {error: "Forbidden"}.to_json,
        headers: {"Content-Type" => "application/json"}
      )
    end
  end

  private def has_required_roles?(user : User) : Bool
    (@required_roles & user.roles).any?
  end
end
```

### Request Enrichment Middleware

```crystal
class RequestEnrichmentMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @enrichment_service : EnrichmentService)
  end

  def call(request : HttpRequest, response : Response) : Response
    # Enrich request with additional data
    enriched_data = @enrichment_service.enrich(request)
    request.set_context(:enriched_data, enriched_data)

    @next.call(request, response)
  end
end
```

### Response Transformation Middleware

```crystal
class ResponseTransformationMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @transformer : ResponseTransformer)
  end

  def call(request : HttpRequest, response : Response) : Response
    # Get response from next handler
    original_response = @next.call(request, response)

    # Transform the response
    @transformer.transform(original_response)
  end
end

class ResponseTransformer
  def transform(response : Response) : Response
    case response.content_type
    when "application/json"
      transform_json_response(response)
    when "text/html"
      transform_html_response(response)
    else
      response
    end
  end

  private def transform_json_response(response : Response) : Response
    # Transform JSON response
    data = JSON.parse(response.body)
    transformed_data = transform_data(data)

    Response.new(
      status: response.status,
      body: transformed_data.to_json,
      headers: response.headers
    )
  end

  private def transform_data(data : JSON::Any) : JSON::Any
    # Custom transformation logic
    data
  end
end
```

### Caching Middleware

```crystal
class CachingMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @cache : Cache, @ttl : Time::Span = 1.hour)
  end

  def call(request : HttpRequest, response : Response) : Response
    # Only cache GET requests
    return @next.call(request, response) unless request.method == "GET"

    cache_key = generate_cache_key(request)

    if cached_response = @cache.get(cache_key)
      # Return cached response
      Response.new(
        status: 200,
        body: cached_response,
        headers: {
          "Content-Type" => "application/json",
          "X-Cache" => "HIT"
        }
      )
    else
      # Get fresh response and cache it
      fresh_response = @next.call(request, response)

      if fresh_response.status == 200
        @cache.set(cache_key, fresh_response.body, @ttl)
      end

      fresh_response
    end
  end

  private def generate_cache_key(request : HttpRequest) : String
    "cache:#{request.method}:#{request.path}:#{request.query_string}"
  end
end
```

### Metrics Middleware

```crystal
class MetricsMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @metrics : MetricsCollector)
  end

  def call(request : HttpRequest, response : Response) : Response
    start_time = Time.monotonic

    begin
      result = @next.call(request, response)

      # Record success metrics
      record_metrics(request, result, start_time, nil)

      result
    rescue ex : Exception
      # Record error metrics
      record_metrics(request, nil, start_time, ex)
      raise ex
    end
  end

  private def record_metrics(request : HttpRequest, response : Response?, start_time : Time::Monotonic, error : Exception?)
    duration = Time.monotonic - start_time

    @metrics.record_request(
      method: request.method,
      path: request.path,
      status: response.try(&.status) || 500,
      duration: duration,
      error: error.try(&.class.name)
    )
  end
end
```

## Advanced Patterns

### Conditional Middleware

```crystal
class ConditionalMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @condition : Proc(HttpRequest, Bool))
  end

  def call(request : HttpRequest, response : Response) : Response
    if @condition.call(request)
      # Apply middleware logic
      process_request(request, response)
    end

    @next.call(request, response)
  end

  private def process_request(request : HttpRequest, response : Response) : Nil
    # Conditional processing logic
  end
end

# Usage
ConditionalMiddleware.new(
  next_handler,
  ->(request : HttpRequest) { request.path.starts_with?("/api/") }
)
```

### Middleware Composition

```crystal
class ComposedMiddleware
  include Azu::Handler

  def initialize(@middlewares : Array(Azu::Handler))
  end

  def call(request : HttpRequest, response : Response) : Response
    # Create a chain of middleware
    chain = @middlewares.reduce(nil) do |next_handler, middleware|
      if next_handler
        middleware.class.new(next_handler)
      else
        middleware
      end
    end

    chain.try(&.call(request, response)) || response
  end
end
```

### Async Middleware

```crystal
class AsyncMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @async_service : AsyncService)
  end

  def call(request : HttpRequest, response : Response) : Response
    # Start async processing
    spawn do
      @async_service.process_async(request)
    end

    # Continue with synchronous processing
    @next.call(request, response)
  end
end
```

## Error Handling

### Error Recovery Middleware

```crystal
class ErrorRecoveryMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @fallback_service : FallbackService)
  end

  def call(request : HttpRequest, response : Response) : Response
    @next.call(request, response)
  rescue ex : ServiceUnavailableException
    # Use fallback service
    fallback_response = @fallback_service.get_fallback_response(request)

    Response.new(
      status: 503,
      body: fallback_response,
      headers: {"Content-Type" => "application/json"}
    )
  rescue ex : Exception
    # Log and re-raise
    Log.error { "Middleware error: #{ex.message}" }
    raise ex
  end
end
```

### Circuit Breaker Middleware

```crystal
class CircuitBreakerMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @circuit_breaker : CircuitBreaker)
  end

  def call(request : HttpRequest, response : Response) : Response
    @circuit_breaker.call do
      @next.call(request, response)
    end
  end
end

class CircuitBreaker
  def initialize(@failure_threshold : Int32 = 5, @timeout : Time::Span = 30.seconds)
    @failures = 0
    @last_failure = nil
    @state = :closed
  end

  def call(&block : -> Response) : Response
    case @state
    when :open
      if should_attempt_reset?
        @state = :half_open
      else
        raise CircuitBreakerOpenException.new
      end
    when :half_open
      # Allow one attempt
    end

    result = block.call
    on_success
    result
  rescue ex : Exception
    on_failure
    raise ex
  end

  private def on_success : Nil
    @failures = 0
    @state = :closed
  end

  private def on_failure : Nil
    @failures += 1
    @last_failure = Time.utc

    if @failures >= @failure_threshold
      @state = :open
    end
  end

  private def should_attempt_reset? : Bool
    @last_failure.try { |time| Time.utc - time > @timeout } || false
  end
end
```

## Testing Custom Middleware

### Unit Testing

```crystal
require "spec"

describe AuthenticationMiddleware do
  it "authenticates valid tokens" do
    auth_service = MockAuthService.new
    auth_service.should_receive(:authenticate).with("valid-token").and_return(User.new("user-1"))

    middleware = AuthenticationMiddleware.new(MockHandler.new, auth_service)

    request = HttpRequest.new("GET", "/api/data")
    request.headers["Authorization"] = "Bearer valid-token"

    response = middleware.call(request, Response.new)

    response.status.should eq(200)
    request.context(:current_user).should be_a(User)
  end

  it "rejects invalid tokens" do
    auth_service = MockAuthService.new
    auth_service.should_receive(:authenticate).with("invalid-token").and_return(nil)

    middleware = AuthenticationMiddleware.new(MockHandler.new, auth_service)

    request = HttpRequest.new("GET", "/api/data")
    request.headers["Authorization"] = "Bearer invalid-token"

    response = middleware.call(request, Response.new)

    response.status.should eq(401)
  end
end
```

### Integration Testing

```crystal
describe "Middleware Integration" do
  it "processes request through middleware chain" do
    app = ExampleApp.new([
      AuthenticationMiddleware.new(MockAuthService.new),
      AuthorizationMiddleware.new(["admin"]),
      MockHandler.new
    ])

    request = HttpRequest.new("GET", "/admin/data")
    request.headers["Authorization"] = "Bearer admin-token"

    response = app.process(request)

    response.status.should eq(200)
  end
end
```

## Performance Considerations

### Middleware Ordering

```crystal
# Optimal middleware order for performance
ExampleApp.start [
  # 1. Error handling (always first)
  Azu::Handler::Rescuer.new,

  # 2. Authentication (early rejection)
  AuthenticationMiddleware.new(auth_service),

  # 3. Authorization (early rejection)
  AuthorizationMiddleware.new(["admin"]),

  # 4. Logging (after auth for user context)
  Azu::Handler::Logger.new,

  # 5. Caching (before expensive operations)
  CachingMiddleware.new(cache),

  # 6. Business logic
  YourEndpoint.new
]
```

### Lazy Loading

```crystal
class LazyLoadingMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @service_factory : -> Service)
    @service = nil
  end

  def call(request : HttpRequest, response : Response) : Response
    # Lazy load service only when needed
    service = @service ||= @service_factory.call

    # Use service
    service.process(request)

    @next.call(request, response)
  end
end
```

### Resource Cleanup

```crystal
class ResourceMiddleware
  include Azu::Handler

  def initialize(@next : Azu::Handler, @resource_pool : ResourcePool)
  end

  def call(request : HttpRequest, response : Response) : Response
    resource = @resource_pool.acquire

    begin
      result = @next.call(request, response)
      result
    ensure
      @resource_pool.release(resource)
    end
  end
end
```

## Best Practices

### 1. Keep Middleware Focused

```crystal
# Good: Single responsibility
class AuthenticationMiddleware
  # Only handles authentication
end

class AuthorizationMiddleware
  # Only handles authorization
end

# Bad: Multiple responsibilities
class AuthMiddleware
  # Handles both authentication and authorization
end
```

### 2. Use Configuration Objects

```crystal
# Good: Structured configuration
class ConfigurableMiddleware
  def initialize(@next : Azu::Handler, @config : Config)
  end

  struct Config
    property enabled : Bool = true
    property timeout : Time::Span = 30.seconds
    property retries : Int32 = 3
  end
end
```

### 3. Handle Errors Gracefully

```crystal
# Good: Proper error handling
def call(request : HttpRequest, response : Response) : Response
  @next.call(request, response)
rescue ex : ServiceException
  # Handle service errors
  handle_service_error(request, ex)
rescue ex : Exception
  # Log and re-raise unexpected errors
  Log.error { "Unexpected error: #{ex.message}" }
  raise ex
end
```

### 4. Use Context for Data Passing

```crystal
# Good: Use request context
def call(request : HttpRequest, response : Response) : Response
  user = authenticate_user(request)
  request.set_context(:current_user, user)

  @next.call(request, response)
end

# Bad: Modify request directly
def call(request : HttpRequest, response : Response) : Response
  user = authenticate_user(request)
  request.user = user  # Don't modify request directly

  @next.call(request, response)
end
```

### 5. Document Your Middleware

```crystal
# Good: Documented middleware
# Handles user authentication by validating JWT tokens
# and setting the current user in the request context.
class AuthenticationMiddleware
  include Azu::Handler

  # @param auth_service [AuthService] Service for token validation
  # @param token_header [String] Header name containing the token
  def initialize(@next : Azu::Handler, @auth_service : AuthService, @token_header : String = "Authorization")
  end

  # Authenticates the request and sets the current user in context
  # @return [Response] The response from the next handler or 401 if unauthorized
  def call(request : HttpRequest, response : Response) : Response
    # Implementation...
  end
end
```

## Registration and Usage

### Registering Middleware

```crystal
# In your application configuration
ExampleApp.start [
  # Built-in middleware
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,

  # Custom middleware
  AuthenticationMiddleware.new(auth_service),
  AuthorizationMiddleware.new(["admin", "user"]),
  CachingMiddleware.new(redis_cache),
  MetricsMiddleware.new(metrics_collector),

  # Your endpoints
  UserEndpoint.new,
  AdminEndpoint.new
]
```

### Environment-Specific Middleware

```crystal
# config/development.cr
ExampleApp.start [
  Azu::Handler::Rescuer.new(show_details: true),
  Azu::Handler::Logger.new(level: :debug),
  DebugMiddleware.new,  # Development-only middleware
  YourEndpoints.new
]

# config/production.cr
ExampleApp.start [
  Azu::Handler::Rescuer.new(show_details: false),
  Azu::Handler::Logger.new(level: :info),
  CachingMiddleware.new(redis_cache),
  MetricsMiddleware.new(metrics_collector),
  YourEndpoints.new
]
```

## Next Steps

- [Built-in Handlers](built-in.md) - Using Azu's built-in middleware
- [Error Handling](errors.md) - Advanced error handling strategies
- [API Reference: Handlers](../api-reference/handlers.md) - Complete handler API documentation
- [Performance Tuning](../advanced/performance-tuning.md) - Optimizing middleware performance

---

_Custom middleware enables you to extend Azu's functionality while maintaining the framework's type safety and performance characteristics._

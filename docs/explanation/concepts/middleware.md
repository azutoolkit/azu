# Understanding Middleware

This document explains Azu's middleware system, called handlers, and how they enable cross-cutting concerns.

## What is Middleware?

Middleware are components that process requests before and after your endpoint logic. They form a chain through which every request passes:

```
Request → Handler 1 → Handler 2 → Handler 3 → Endpoint
                                                   ↓
Response ← Handler 1 ← Handler 2 ← Handler 3 ← Response
```

## The Handler Pattern

In Azu, middleware are called "handlers" and extend `Azu::Handler::Base`:

```crystal
class MyHandler < Azu::Handler::Base
  def call(context)
    # Before request processing
    call_next(context)
    # After request processing
  end
end
```

### The call_next Pattern

`call_next(context)` passes control to the next handler:

```crystal
def call(context)
  puts "Before"
  call_next(context)
  puts "After"
end
```

Output for a request:
```
Before
  Before (next handler)
    [Endpoint executes]
  After (next handler)
After
```

## Handler Chain

Handlers execute in registration order:

```crystal
MyApp.start [
  Azu::Handler::Rescuer.new,   # 1. Outermost
  Azu::Handler::Logger.new,    # 2.
  AuthHandler.new,              # 3.
  RateLimitHandler.new,         # 4.
  MyEndpoint.new,               # 5. Innermost
]
```

For a request:
1. Rescuer wraps everything in error handling
2. Logger records start time
3. Auth checks credentials
4. Rate limiter checks quota
5. Endpoint handles request
6. Rate limiter continues
7. Auth continues
8. Logger logs duration
9. Rescuer returns response

## Use Cases

### Cross-Cutting Concerns

Handlers are ideal for concerns that span multiple endpoints:

| Concern | Handler |
|---------|---------|
| Error handling | Rescuer |
| Logging | Logger |
| Authentication | AuthHandler |
| Rate limiting | RateLimitHandler |
| CORS | CorsHandler |
| Compression | CompressionHandler |
| Caching | CacheHandler |

### Request Modification

Add or modify request data:

```crystal
class RequestIdHandler < Azu::Handler::Base
  def call(context)
    request_id = context.request.headers["X-Request-ID"]?
    request_id ||= UUID.random.to_s

    context.request.headers["X-Request-ID"] = request_id
    call_next(context)
  end
end
```

### Response Modification

Modify response after endpoint:

```crystal
class SecurityHeadersHandler < Azu::Handler::Base
  def call(context)
    call_next(context)

    context.response.headers["X-Frame-Options"] = "DENY"
    context.response.headers["X-Content-Type-Options"] = "nosniff"
  end
end
```

### Short-Circuiting

Stop processing early:

```crystal
class AuthHandler < Azu::Handler::Base
  def call(context)
    unless authenticated?(context)
      context.response.status_code = 401
      context.response.print({error: "Unauthorized"}.to_json)
      return  # Don't call_next - stop here
    end

    call_next(context)
  end
end
```

## Handler vs Endpoint

### When to Use Handlers

- Applies to multiple routes
- Cross-cutting concern
- Modifies request/response metadata
- Need to wrap endpoint execution

### When to Use Endpoints

- Specific business logic
- Single route
- Main request handling
- Produces the response body

## Handler Composition

### Conditional Handlers

Apply logic conditionally:

```crystal
class AdminOnlyHandler < Azu::Handler::Base
  def call(context)
    if admin_route?(context.request.path)
      verify_admin!(context)
    end

    call_next(context)
  end

  private def admin_route?(path)
    path.starts_with?("/admin")
  end
end
```

### Handler with State

Handlers can maintain state (use carefully):

```crystal
class MetricsHandler < Azu::Handler::Base
  @request_count = Atomic(Int64).new(0)

  def call(context)
    @request_count.add(1)
    call_next(context)
  end

  def request_count
    @request_count.get
  end
end
```

### Configurable Handlers

Accept configuration in constructor:

```crystal
class RateLimitHandler < Azu::Handler::Base
  def initialize(@limit : Int32 = 100, @window : Time::Span = 1.minute)
  end

  def call(context)
    if rate_limited?(context)
      context.response.status_code = 429
      return
    end

    call_next(context)
  end
end

# Usage
RateLimitHandler.new(limit: 200, window: 30.seconds)
```

## Ordering Best Practices

Recommended handler order:

```crystal
MyApp.start [
  # 1. Error handling (catches everything)
  Azu::Handler::Rescuer.new,

  # 2. Request ID (for tracing)
  RequestIdHandler.new,

  # 3. CORS (early for preflight)
  CorsHandler.new,

  # 4. Logging (after IDs, before auth)
  LoggingHandler.new,

  # 5. Rate limiting (before expensive ops)
  RateLimitHandler.new,

  # 6. Authentication
  AuthHandler.new,

  # 7. Static files (can skip auth)
  StaticHandler.new,

  # 8. Endpoints
  UsersEndpoint.new,
  PostsEndpoint.new,
]
```

## Error Handling

The Rescuer handler catches exceptions:

```crystal
class Azu::Handler::Rescuer < Base
  def call(context)
    call_next(context)
  rescue ex : Response::Error
    render_error(context, ex)
  rescue ex
    render_internal_error(context, ex)
  end
end
```

Always place Rescuer first so it catches errors from all handlers.

## Testing Handlers

Test handlers in isolation:

```crystal
describe AuthHandler do
  it "allows authenticated requests" do
    context = create_context(headers: {"Authorization" => "Bearer valid"})
    handler = AuthHandler.new

    handler.call(context)

    context.response.status_code.should_not eq(401)
  end

  it "rejects unauthenticated requests" do
    context = create_context
    handler = AuthHandler.new

    handler.call(context)

    context.response.status_code.should eq(401)
  end
end
```

## See Also

- [Handler Reference](../../reference/handlers/built-in.md)
- [How to Create Custom Middleware](../../how-to/middleware/create-custom-middleware.md)
- [Request Lifecycle](../architecture/request-lifecycle.md)

# Built-in Handlers Reference

Azu provides several built-in handlers for common middleware needs.

## Handler::Base

Base class for all handlers.

```crystal
class MyHandler < Azu::Handler::Base
  def call(context)
    # Before processing
    call_next(context)
    # After processing
  end
end
```

### Methods

#### call

Handle the request. Must be implemented.

```crystal
def call(context : HTTP::Server::Context)
  # Handle request
end
```

#### call_next

Pass to next handler in chain.

```crystal
def call(context)
  call_next(context)
end
```

## Handler::Rescuer

Catches exceptions and returns error responses.

```crystal
MyApp.start [
  Azu::Handler::Rescuer.new,
  # ... other handlers
]
```

### Behavior

| Exception | Status | Response |
|-----------|--------|----------|
| `Response::NotFound` | 404 | Not Found |
| `Response::BadRequest` | 400 | Bad Request |
| `Response::Unauthorized` | 401 | Unauthorized |
| `Response::Forbidden` | 403 | Forbidden |
| `Response::ValidationError` | 422 | Validation errors |
| `Response::Error` | varies | Error message |
| Other exceptions | 500 | Internal Server Error |

### Development Mode

In development, shows detailed error page with:
- Exception message
- Backtrace
- Request details

### Production Mode

Returns JSON error:

```json
{
  "error": "Internal Server Error"
}
```

## Handler::Logger

Logs HTTP requests.

```crystal
MyApp.start [
  Azu::Handler::Logger.new,
  # ... other handlers
]
```

### Log Format

```
2024-01-15T10:30:00Z INFO  GET /users 200 15.2ms
```

### Configuration

```crystal
Azu::Handler::Logger.new(
  log: Log.for("http"),
  skip_paths: ["/health", "/metrics"]
)
```

**Options:**
- `log : Log` - Logger instance
- `skip_paths : Array(String)` - Paths to skip logging

## Handler::Static

Serves static files.

```crystal
MyApp.start [
  Azu::Handler::Static.new(
    public_dir: "./public",
    fallthrough: true
  ),
  # ... other handlers
]
```

**Options:**
- `public_dir : String` - Directory to serve from
- `fallthrough : Bool` - Pass to next handler if not found
- `directory_listing : Bool` - Show directory listings

### File Types

Automatically sets Content-Type based on extension:
- `.html` → `text/html`
- `.css` → `text/css`
- `.js` → `application/javascript`
- `.json` → `application/json`
- `.png` → `image/png`
- `.jpg` → `image/jpeg`

## Handler::CORS

Handles Cross-Origin Resource Sharing.

```crystal
MyApp.start [
  Azu::Handler::CORS.new(
    allowed_origins: ["https://example.com"],
    allowed_methods: ["GET", "POST", "PUT", "DELETE"],
    allowed_headers: ["Content-Type", "Authorization"],
    max_age: 86400
  ),
  # ... other handlers
]
```

**Options:**
- `allowed_origins : Array(String)` - Allowed origins (`["*"]` for all)
- `allowed_methods : Array(String)` - Allowed HTTP methods
- `allowed_headers : Array(String)` - Allowed request headers
- `exposed_headers : Array(String)` - Headers exposed to client
- `max_age : Int32` - Preflight cache duration in seconds
- `allow_credentials : Bool` - Allow cookies/auth

### Response Headers

```
Access-Control-Allow-Origin: https://example.com
Access-Control-Allow-Methods: GET, POST, PUT, DELETE
Access-Control-Allow-Headers: Content-Type, Authorization
Access-Control-Max-Age: 86400
```

## Handler Pipeline

Handlers execute in order:

```crystal
MyApp.start [
  # 1. First: Handle errors
  Azu::Handler::Rescuer.new,

  # 2. Add CORS headers
  Azu::Handler::CORS.new,

  # 3. Log requests
  Azu::Handler::Logger.new,

  # 4. Serve static files
  Azu::Handler::Static.new(public_dir: "./public"),

  # 5. Custom middleware
  AuthHandler.new,
  RateLimitHandler.new,

  # 6. Endpoints
  UsersEndpoint.new,
  PostsEndpoint.new,
]
```

## Creating Custom Handlers

```crystal
class TimingHandler < Azu::Handler::Base
  def call(context)
    start = Time.monotonic

    call_next(context)

    duration = Time.monotonic - start
    context.response.headers["X-Response-Time"] = "#{duration.total_milliseconds}ms"
  end
end

class AuthHandler < Azu::Handler::Base
  SKIP_PATHS = ["/", "/login", "/health"]

  def call(context)
    path = context.request.path

    if SKIP_PATHS.includes?(path)
      return call_next(context)
    end

    token = context.request.headers["Authorization"]?

    unless token && valid?(token)
      context.response.status_code = 401
      context.response.print({error: "Unauthorized"}.to_json)
      return
    end

    call_next(context)
  end

  private def valid?(token : String) : Bool
    # Validate token
    true
  end
end
```

## Handler Order Best Practices

1. **Rescuer** - First, catches all errors
2. **CORS** - Early, for preflight requests
3. **Logger** - After CORS, logs all requests
4. **Static** - Before auth, for public assets
5. **Auth** - Before business logic
6. **Rate Limit** - Protect endpoints
7. **Endpoints** - Business logic

## See Also

- [Core Reference](../api/core.md)
- [How to Create Custom Middleware](../../how-to/middleware/create-custom-middleware.md)

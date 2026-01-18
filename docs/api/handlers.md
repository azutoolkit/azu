# Handlers API

Handlers provide middleware functionality for Azu applications, allowing you to process requests and responses at different stages of the request lifecycle.

## Built-in Handlers

### Azu::Handler::Rescuer

Handles exceptions and provides error responses.

```crystal
Azu.start [
  Azu::Handler::Rescuer.new
]
```

**Features:**

- Automatic exception handling
- Development-friendly error pages
- Production-safe error responses
- Stack trace logging in development

### Azu::Handler::Logger

Provides request/response logging.

```crystal
Azu.start [
  Azu::Handler::Logger.new
]
```

**Features:**

- Request method and path logging
- Response status and timing
- Error logging
- Configurable log levels

### Azu::Handler::CORS

Handles Cross-Origin Resource Sharing (CORS) headers.

```crystal
Azu.start [
  Azu::Handler::CORS.new(
    origins: ["http://localhost:3000", "https://example.com"],
    methods: ["GET", "POST", "PUT", "DELETE"],
    headers: ["Content-Type", "Authorization"]
  )
]
```

**Configuration:**

- `origins` - Allowed origins
- `methods` - Allowed HTTP methods
- `headers` - Allowed headers
- `credentials` - Allow credentials

### Azu::Handler::Static

Serves static files from a directory.

```crystal
Azu.start [
  Azu::Handler::Static.new(
    directory: "public",
    prefix: "/static"
  )
]
```

**Configuration:**

- `directory` - Directory to serve files from
- `prefix` - URL prefix for static files
- `index` - Default file to serve for directories

### Azu::Handler::CSRF

Provides CSRF protection for state-changing operations following OWASP recommendations.

```crystal
Azu.start [
  Azu::Handler::CSRF.new(
    skip_routes: ["/api/webhooks"],
    strategy: Azu::Handler::CSRF::Strategy::SignedDoubleSubmit,
    secret_key: ENV["CSRF_SECRET"]?,
    cookie_name: "csrf_token",
    header_name: "X-CSRF-TOKEN",
    param_name: "_csrf",
    cookie_max_age: 86400,
    cookie_same_site: HTTP::Cookie::SameSite::Strict,
    secure_cookies: true
  )
]
```

**Protection Strategies:**

| Strategy | Description | Recommendation |
|----------|-------------|----------------|
| `SignedDoubleSubmit` | HMAC-signed token with timestamp validation | Recommended (default) |
| `SynchronizerToken` | Token stored in cookie, verified against form/header | Good |
| `DoubleSubmit` | Simple double submit cookie | Not recommended |

**Configuration Options:**

- `skip_routes` - Array of paths to bypass CSRF protection
- `strategy` - Protection strategy (default: `SignedDoubleSubmit`)
- `secret_key` - HMAC secret key (auto-generated if not provided)
- `cookie_name` - Cookie name (default: `csrf_token`)
- `header_name` - Header name for AJAX (default: `X-CSRF-TOKEN`)
- `param_name` - Form parameter name (default: `_csrf`)
- `cookie_max_age` - Token expiry in seconds (default: 86400 / 24 hours)
- `cookie_same_site` - SameSite policy (default: `Strict`)
- `secure_cookies` - Use secure cookies (default: `true`)

**Helper Methods:**

```crystal
# In your endpoint
def call : MyResponse
  # Generate token for forms
  token = Azu::Handler::CSRF.token(context)

  # Generate hidden input tag
  hidden_field = Azu::Handler::CSRF.tag(context)
  # => <input type="hidden" name="_csrf" value="..." />

  # Generate meta tag for AJAX
  meta_tag = Azu::Handler::CSRF.metatag(context)
  # => <meta name="_csrf" content="..." />

  # Validate origin header
  origin_valid = Azu::Handler::CSRF.validate_origin(context)
end
```

**Strategy Selection:**

```crystal
# Use recommended HMAC-signed strategy (default)
Azu::Handler::CSRF.use_signed_double_submit!

# Use synchronizer token pattern
Azu::Handler::CSRF.use_synchronizer_token!

# Configure via block
Azu::Handler::CSRF.configure do |csrf|
  csrf.strategy = Azu::Handler::CSRF::Strategy::SignedDoubleSubmit
  csrf.secret_key = ENV["CSRF_SECRET"]
end
```

### Azu::Handler::Throttle

Provides rate limiting and DDoS protection.

```crystal
Azu.start [
  Azu::Handler::Throttle.new(
    interval: 5,          # Reset counter every 5 seconds
    duration: 900,        # Block for 15 minutes
    threshold: 100,       # Allow 100 requests per interval
    blacklist: ["1.2.3.4"],  # Immediately block these IPs
    whitelist: ["127.0.0.1"] # Always allow these IPs
  )
]
```

**Configuration Options:**

- `interval` - Duration in seconds until request counter resets (default: 5)
- `duration` - Duration in seconds to block an IP (default: 900 / 15 minutes)
- `threshold` - Number of requests allowed per interval (default: 100)
- `blacklist` - Array of IPs to immediately block
- `whitelist` - Array of IPs to always allow

**Response:**

When rate limited, returns HTTP 429 with `Retry-After` header.

**Monitoring:**

```crystal
throttle = Azu::Handler::Throttle.new(
  interval: 5,
  duration: 900,
  threshold: 100,
  blacklist: [] of String,
  whitelist: [] of String
)

# Get current stats
stats = throttle.stats
# => {tracked_ips: 42, blocked_ips: 3}

# Reset all tracking (useful for testing)
throttle.reset
```

### Azu::Handler::RequestId

Adds unique request IDs for distributed tracing.

```crystal
Azu.start [
  Azu::Handler::RequestId.new
]
```

**Features:**

- Generates or uses existing `X-Request-ID` header
- Enables request correlation across services
- Useful for debugging and log aggregation

### Azu::Handler::PerformanceMonitor

Tracks request and component performance metrics (compile-time optional).

```crystal
Azu.start [
  Azu::Handler::PerformanceMonitor.new
]
```

**Features:**

- Request processing time tracking
- Component lifecycle metrics
- Memory usage monitoring
- Enable via `PERFORMANCE_MONITORING=true` compile flag

## Custom Handlers

Create custom handlers by inheriting from `Azu::Handler::Base`.

### Basic Handler

```crystal
class CustomHandler < Azu::Handler::Base
  def call(request, response)
    # Process request
    yield
    # Process response
  end
end
```

### Handler with Configuration

```crystal
class RateLimitHandler < Azu::Handler::Base
  def initialize(@limit : Int32, @window : Time::Span)
  end

  def call(request, response)
    # Rate limiting logic
    yield
  end
end
```

### Handler with State

```crystal
class SessionHandler < Azu::Handler::Base
  def initialize
    @sessions = {} of String => Hash(String, String)
  end

  def call(request, response)
    # Session management
    yield
  end
end
```

## Handler Lifecycle

Handlers are executed in the order they are added to the middleware stack.

### Request Phase

```crystal
def call(request, response)
  # 1. Pre-processing
  process_request(request)

  # 2. Call next handler
  yield

  # 3. Post-processing
  process_response(response)
end
```

### Error Handling

```crystal
def call(request, response)
  begin
    yield
  rescue ex
    handle_error(ex, request, response)
  end
end
```

## Handler Registration

### Application Level

```crystal
Azu.start [
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  Azu::Handler::CORS.new,
  Azu::Handler::Static.new
]
```

### Endpoint Level

```crystal
struct UserEndpoint
  include Azu::Endpoint

  get "/users/:id"

  def call
    # Endpoint logic
  end
end
```

## Handler Configuration

### Environment-based Configuration

```crystal
handlers = [] of Azu::Handler::Base

if Azu::Environment.development?
  handlers << Azu::Handler::Logger.new
  handlers << Azu::Handler::Rescuer.new
end

handlers << Azu::Handler::CORS.new
handlers << Azu::Handler::Static.new

Azu.start(handlers)
```

### Conditional Handlers

```crystal
handlers = [] of Azu::Handler::Base

# Add CORS only for API endpoints
if request.path.starts_with?("/api")
  handlers << Azu::Handler::CORS.new
end

# Add CSRF protection for state-changing operations
if request.method.in?(["POST", "PUT", "PATCH", "DELETE"])
  handlers << Azu::Handler::CSRF.new
end
```

## Handler Testing

### Unit Testing

```crystal
describe CustomHandler do
  it "processes requests correctly" do
    handler = CustomHandler.new
    request = create_test_request
    response = create_test_response

    handler.call(request, response) do
      # Test logic
    end
  end
end
```

### Integration Testing

```crystal
describe "Handler Integration" do
  it "works with other handlers" do
    Azu.start [
      Azu::Handler::Logger.new,
      CustomHandler.new,
      Azu::Handler::Rescuer.new
    ]

    # Test with real requests
  end
end
```

## Performance Considerations

### Handler Order

Order handlers by their processing requirements:

1. **Security handlers** (CORS, CSRF)
2. **Logging handlers** (Logger)
3. **Business logic handlers** (Custom)
4. **Error handlers** (Rescuer)

### Handler Efficiency

```crystal
class EfficientHandler < Azu::Handler::Base
  def call(request, response)
    # Only process if necessary
    return yield unless should_process?(request)

    # Efficient processing
    yield
  end
end
```

## Common Patterns

### Authentication Handler

```crystal
class AuthHandler < Azu::Handler::Base
  def call(request, response)
    token = request.header("Authorization")

    if token && valid_token?(token)
      yield
    else
      response.status(401)
      response.body("Unauthorized")
    end
  end
end
```

### Rate Limiting Handler

```crystal
class RateLimitHandler < Azu::Handler::Base
  def initialize(@limit : Int32, @window : Time::Span)
    @requests = {} of String => Array(Time)
  end

  def call(request, response)
    client_ip = request.remote_ip
    now = Time.utc

    # Clean old requests
    @requests[client_ip] = @requests[client_ip].select { |t| now - t < @window }

    if @requests[client_ip].size >= @limit
      response.status(429)
      response.body("Rate limit exceeded")
    else
      @requests[client_ip] << now
      yield
    end
  end
end
```

### Caching Handler

```crystal
class CacheHandler < Azu::Handler::Base
  def initialize(@ttl : Time::Span)
    @cache = {} of String => {String, Time}
  end

  def call(request, response)
    cache_key = "#{request.method}:#{request.path}"

    if cached = @cache[cache_key]?
      if Time.utc - cached[1] < @ttl
        response.body(cached[0])
        return
      end
    end

    yield

    # Cache the response
    @cache[cache_key] = {response.body, Time.utc}
  end
end
```

## Next Steps

- Learn about [Configuration](configuration.md)
- Explore [Error Handling](errors.md)
- Understand [Middleware Patterns](middleware.md)
- See [Performance Optimization](performance.md)

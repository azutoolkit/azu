# Handler Classes API Reference

This document provides a comprehensive reference for Azu's built-in middleware handlers, including their configuration options and usage patterns.

## Base Handler

### `Azu::Handler::Base`

The base class for all middleware handlers.

```crystal
abstract class Azu::Handler::Base
  # Base class for all middleware handlers
end
```

#### Methods

##### `call(context : HTTP::Server::Context)`

Process the HTTP request/response through the middleware.

```crystal
def call(context : HTTP::Server::Context)
  # Process request
  call_next(context)
  # Process response
end
```

##### `call_next(context : HTTP::Server::Context)`

Call the next handler in the middleware stack.

```crystal
def call_next(context : HTTP::Server::Context)
  # Implementation
end
```

## Built-in Handlers

### Logger Handler

#### `Azu::Handler::Logger`

Provides request/response logging with configurable formats.

```crystal
class Azu::Handler::Logger < Azu::Handler::Base
  # Logs HTTP requests and responses
end
```

##### Constructor

```crystal
Logger.new(
  format: LogFormat::Common,
  level: Log::Severity::Info,
  exclude_paths: [] of String
)
```

**Parameters:**

- `format` - Log format (Common, Combined, Custom)
- `level` - Log level (Debug, Info, Warn, Error)
- `exclude_paths` - Paths to exclude from logging

##### Usage

```crystal
# Basic usage
Azu::Handler::Logger.new

# With custom format
Azu::Handler::Logger.new(
  format: Azu::LogFormat::Combined,
  level: Log::Severity::Debug
)

# Exclude health check endpoints
Azu::Handler::Logger.new(
  exclude_paths: ["/health", "/metrics"]
)
```

### Rescuer Handler

#### `Azu::Handler::Rescuer`

Handles exceptions and provides error responses.

```crystal
class Azu::Handler::Rescuer < Azu::Handler::Base
  # Handles exceptions and provides error responses
end
```

##### Constructor

```crystal
Rescuer.new(
  show_details: false,
  log_errors: true,
  custom_handlers: {} of String.class => Proc(Exception, HTTP::Server::Context, Nil)
)
```

**Parameters:**

- `show_details` - Show exception details in development
- `log_errors` - Log exceptions
- `custom_handlers` - Custom exception handlers

##### Usage

```crystal
# Basic usage
Azu::Handler::Rescuer.new

# Show details in development
Azu::Handler::Rescuer.new(
  show_details: EnvironmentManager.development?
)

# Custom exception handlers
custom_handlers = {
  ValidationError => ->(ex : Exception, context : HTTP::Server::Context) {
    context.response.status_code = 422
    context.response.print({error: ex.message}.to_json)
  }
}

Azu::Handler::Rescuer.new(
  custom_handlers: custom_handlers
)
```

### CORS Handler

#### `Azu::Handler::CORS`

Handles Cross-Origin Resource Sharing (CORS) headers.

```crystal
class Azu::Handler::CORS < Azu::Handler::Base
  # Handles CORS headers
end
```

##### Constructor

```crystal
CORS.new(
  origins: ["*"],
  methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
  headers: ["Content-Type", "Authorization"],
  credentials: false,
  max_age: 86400
)
```

**Parameters:**

- `origins` - Allowed origins (use `["*"]` for all)
- `methods` - Allowed HTTP methods
- `headers` - Allowed headers
- `credentials` - Allow credentials
- `max_age` - Preflight cache duration

##### Usage

```crystal
# Allow all origins
Azu::Handler::CORS.new

# Specific origins
Azu::Handler::CORS.new(
  origins: ["https://example.com", "https://app.example.com"],
  credentials: true
)

# Development settings
Azu::Handler::CORS.new(
  origins: ["http://localhost:3000", "http://localhost:3001"],
  methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"],
  headers: ["Content-Type", "Authorization", "X-Requested-With"]
)
```

### Static Handler

#### `Azu::Handler::Static`

Serves static files from a directory.

```crystal
class Azu::Handler::Static < Azu::Handler::Base
  # Serves static files
end
```

##### Constructor

```crystal
Static.new(
  path: "public",
  index: "index.html",
  headers: {} of String => String,
  gzip: true,
  cache_control: "public, max-age=31536000"
)
```

**Parameters:**

- `path` - Directory to serve files from
- `index` - Default index file
- `headers` - Additional headers to add
- `gzip` - Enable gzip compression
- `cache_control` - Cache control header

##### Usage

```crystal
# Basic usage
Azu::Handler::Static.new

# Custom path
Azu::Handler::Static.new(path: "assets")

# With custom headers
Azu::Handler::Static.new(
  path: "public",
  headers: {
    "X-Frame-Options" => "DENY",
    "X-Content-Type-Options" => "nosniff"
  }
)

# Development settings (no caching)
Azu::Handler::Static.new(
  cache_control: "no-cache, no-store, must-revalidate"
)
```

### Throttle Handler

#### `Azu::Handler::Throttle`

Implements rate limiting for requests.

```crystal
class Azu::Handler::Throttle < Azu::Handler::Base
  # Implements rate limiting
end
```

##### Constructor

```crystal
Throttle.new(
  requests_per_minute: 60,
  requests_per_hour: 1000,
  key_generator: ->(context : HTTP::Server::Context) { String },
  store: MemoryStore.new,
  headers: true
)
```

**Parameters:**

- `requests_per_minute` - Requests allowed per minute
- `requests_per_hour` - Requests allowed per hour
- `key_generator` - Function to generate rate limit keys
- `store` - Storage backend for rate limit data
- `headers` - Include rate limit headers in response

##### Usage

```crystal
# Basic usage (60 requests per minute)
Azu::Handler::Throttle.new

# Stricter limits
Azu::Handler::Throttle.new(
  requests_per_minute: 30,
  requests_per_hour: 500
)

# Custom key generator (by IP)
Azu::Handler::Throttle.new(
  key_generator: ->(context : HTTP::Server::Context) {
    context.request.remote_address.try(&.address) || "unknown"
  }
)

# Redis storage
redis_store = RedisStore.new(Redis::Client.new)
Azu::Handler::Throttle.new(
  store: redis_store,
  requests_per_minute: 100
)
```

### Request ID Handler

#### `Azu::Handler::RequestId`

Adds unique request IDs to track requests across the system.

```crystal
class Azu::Handler::RequestId < Azu::Handler::Base
  # Adds unique request IDs
end
```

##### Constructor

```crystal
RequestId.new(
  header_name: "X-Request-ID",
  generator: ->{ String },
  include_in_response: true
)
```

**Parameters:**

- `header_name` - Name of the request ID header
- `generator` - Function to generate request IDs
- `include_in_response` - Include request ID in response headers

##### Usage

```crystal
# Basic usage
Azu::Handler::RequestId.new

# Custom header name
Azu::Handler::RequestId.new(
  header_name: "X-Correlation-ID"
)

# Custom ID generator
Azu::Handler::RequestId.new(
  generator: ->{ "#{Time.utc.to_unix}-#{Random::Secure.hex(8)}" }
)
```

### CSRF Handler

#### `Azu::Handler::CSRF`

Protects against Cross-Site Request Forgery attacks.

```crystal
class Azu::Handler::CSRF < Azu::Handler::Base
  # CSRF protection
end
```

##### Constructor

```crystal
CSRF.new(
  secret: String,
  token_length: 32,
  header_name: "X-CSRF-Token",
  param_name: "_csrf_token",
  exclude_methods: ["GET", "HEAD", "OPTIONS"],
  exclude_paths: [] of String
)
```

**Parameters:**

- `secret` - Secret key for token generation
- `token_length` - Length of CSRF tokens
- `header_name` - Header name for CSRF token
- `param_name` - Parameter name for CSRF token
- `exclude_methods` - HTTP methods to exclude
- `exclude_paths` - Paths to exclude from CSRF protection

##### Usage

```crystal
# Basic usage
Azu::Handler::CSRF.new(secret: ENV["CSRF_SECRET"])

# Custom configuration
Azu::Handler::CSRF.new(
  secret: ENV["CSRF_SECRET"],
  token_length: 64,
  header_name: "X-XSRF-Token",
  exclude_paths: ["/api/webhooks"]
)

# Development (disabled)
Azu::Handler::CSRF.new(
  secret: "dev-secret",
  exclude_methods: ["GET", "HEAD", "OPTIONS", "POST"]  # Disable for development
)
```

### IP Spoofing Handler

#### `Azu::Handler::IpSpoofing`

Prevents IP address spoofing by validating forwarded headers.

```crystal
class Azu::Handler::IpSpoofing < Azu::Handler::Base
  # Prevents IP address spoofing
end
```

##### Constructor

```crystal
IpSpoofing.new(
  trusted_proxies: [] of String,
  forwarded_for_header: "X-Forwarded-For",
  real_ip_header: "X-Real-IP"
)
```

**Parameters:**

- `trusted_proxies` - List of trusted proxy IPs
- `forwarded_for_header` - Header name for forwarded IPs
- `real_ip_header` - Header name for real IP

##### Usage

```crystal
# Basic usage
Azu::Handler::IpSpoofing.new

# With trusted proxies
Azu::Handler::IpSpoofing.new(
  trusted_proxies: ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
)

# Custom headers
Azu::Handler::IpSpoofing.new(
  forwarded_for_header: "X-Forwarded-For",
  real_ip_header: "X-Real-IP"
)
```

### Simple Logger Handler

#### `Azu::Handler::SimpleLogger`

A simplified logging handler for basic request logging.

```crystal
class Azu::Handler::SimpleLogger < Azu::Handler::Base
  # Simple request logging
end
```

##### Constructor

```crystal
SimpleLogger.new(
  io: IO::STDOUT,
  format: SimpleLogFormat::Common
)
```

**Parameters:**

- `io` - Output stream for logs
- `format` - Log format (Common, Combined)

##### Usage

```crystal
# Basic usage
Azu::Handler::SimpleLogger.new

# Custom output
Azu::Handler::SimpleLogger.new(
  io: File.new("logs/access.log", "a"),
  format: Azu::SimpleLogFormat::Combined
)
```

## Custom Handlers

### Creating Custom Handlers

You can create custom handlers by inheriting from `Azu::Handler::Base`.

```crystal
class CustomAuthHandler < Azu::Handler::Base
  def initialize(@api_key : String)
  end

  def call(context : HTTP::Server::Context)
    api_key = context.request.headers["Authorization"]?

    if api_key != @api_key
      context.response.status_code = 401
      context.response.print({error: "Unauthorized"}.to_json)
      return
    end

    call_next(context)
  end
end
```

### Handler Composition

Handlers can be composed to create complex middleware stacks.

```crystal
class CompositeHandler < Azu::Handler::Base
  def initialize(@handlers : Array(Azu::Handler::Base))
  end

  def call(context : HTTP::Server::Context)
    call_handlers(context, 0)
  end

  private def call_handlers(context : HTTP::Server::Context, index : Int32)
    if index >= @handlers.size
      # End of middleware stack
      return
    end

    @handlers[index].call(context)
  end
end
```

## Handler Configuration

### Environment-Specific Configuration

```crystal
class HandlerConfig
  def self.create_stack : Array(Azu::Handler::Base)
    stack = [] of Azu::Handler::Base

    # Always include these handlers
    stack << Azu::Handler::Rescuer.new(
      show_details: EnvironmentManager.development?
    )
    stack << Azu::Handler::Logger.new(
      level: EnvironmentManager.development? ? Log::Severity::Debug : Log::Severity::Info
    )

    # Environment-specific handlers
    case EnvironmentManager.current
    when EnvironmentManager::DEVELOPMENT
      stack << Azu::Handler::CORS.new(
        origins: ["http://localhost:3000", "http://localhost:3001"],
        credentials: true
      )
      stack << Azu::Handler::Static.new(
        path: "public",
        cache_control: "no-cache"
      )

    when EnvironmentManager::STAGING
      stack << Azu::Handler::CORS.new(
        origins: ["https://staging.example.com"],
        credentials: true
      )
      stack << Azu::Handler::Throttle.new(
        requests_per_minute: 100
      )
      stack << Azu::Handler::RequestId.new

    when EnvironmentManager::PRODUCTION
      stack << Azu::Handler::CORS.new(
        origins: ["https://example.com"],
        credentials: true
      )
      stack << Azu::Handler::Throttle.new(
        requests_per_minute: 60,
        requests_per_hour: 1000
      )
      stack << Azu::Handler::RequestId.new
      stack << Azu::Handler::CSRF.new(
        secret: ENV["CSRF_SECRET"]
      )
      stack << Azu::Handler::IpSpoofing.new(
        trusted_proxies: ["10.0.0.0/8"]
      )
    end

    stack
  end
end
```

### Handler Ordering

The order of handlers in the middleware stack is important:

1. **Rescuer** - Should be first to catch all exceptions
2. **Logger** - Early logging of requests
3. **CORS** - Handle preflight requests
4. **Authentication** - Verify user identity
5. **Authorization** - Check permissions
6. **Rate Limiting** - Prevent abuse
7. **Request Processing** - Your application logic
8. **Static Files** - Serve static content last

```crystal
# Correct order
stack = [
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  Azu::Handler::CORS.new,
  Azu::Handler::Throttle.new,
  Azu::Handler::RequestId.new,
  # Your application handlers
  Azu::Handler::Static.new
]
```

## Handler Testing

### Testing Custom Handlers

```crystal
describe "CustomAuthHandler" do
  it "allows requests with valid API key" do
    handler = CustomAuthHandler.new("valid-key")
    context = create_context(headers: {"Authorization" => "valid-key"})

    handler.call(context)

    assert context.response.status_code == 200
  end

  it "rejects requests with invalid API key" do
    handler = CustomAuthHandler.new("valid-key")
    context = create_context(headers: {"Authorization" => "invalid-key"})

    handler.call(context)

    assert context.response.status_code == 401
  end

  it "rejects requests without API key" do
    handler = CustomAuthHandler.new("valid-key")
    context = create_context

    handler.call(context)

    assert context.response.status_code == 401
  end
end

private def create_context(headers : Hash(String, String) = {} of String => String) : HTTP::Server::Context
  request = HTTP::Request.new("GET", "/")
  headers.each { |key, value| request.headers[key] = value }

  response = HTTP::Server::Response.new(IO::Memory.new)
  HTTP::Server::Context.new(request, response)
end
```

## Performance Considerations

### Handler Performance

- **Logger**: Minimal overhead, but can be expensive with high request volumes
- **CORS**: Very fast, minimal overhead
- **Throttle**: Can be expensive with high concurrency (use Redis for distributed systems)
- **CSRF**: Moderate overhead due to token generation and validation
- **Static**: Very fast for file serving

### Optimization Tips

```crystal
# Use conditional logging
Azu::Handler::Logger.new(
  exclude_paths: ["/health", "/metrics", "/favicon.ico"]
)

# Use efficient rate limiting storage
redis_store = RedisStore.new(redis_client)
Azu::Handler::Throttle.new(
  store: redis_store,
  requests_per_minute: 100
)

# Disable CSRF for API endpoints
Azu::Handler::CSRF.new(
  exclude_paths: ["/api/*"]
)
```

## Next Steps

- [Core Modules](api-reference/core.md) - Core framework modules
- [Configuration Options](api-reference/configuration.md) - Configuration reference
- [Middleware](middleware.md) - Middleware patterns and best practices
- [Advanced Usage](advanced.md) - Advanced handler usage

# How to Create Custom Middleware

This guide shows you how to create custom middleware handlers in Azu.

## Basic Handler

Create a handler by extending `Azu::Handler::Base`:

```crystal
class TimingHandler < Azu::Handler::Base
  def call(context)
    start = Time.instant

    call_next(context)

    duration = Time.instant - start
    context.response.headers["X-Response-Time"] = "#{duration.total_milliseconds.round(2)}ms"
  end
end
```

## Register the Handler

Add your handler to the application pipeline:

```crystal
MyApp.start [
  TimingHandler.new,          # First in chain
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  # ... endpoints
]
```

## Authentication Handler

```crystal
class AuthHandler < Azu::Handler::Base
  EXCLUDED_PATHS = ["/", "/login", "/health"]

  def call(context)
    path = context.request.path

    if EXCLUDED_PATHS.includes?(path)
      return call_next(context)
    end

    token = extract_token(context)

    if token && valid_token?(token)
      # Store user in context for later use
      context.request.headers["X-User-ID"] = user_id_from_token(token).to_s
      call_next(context)
    else
      context.response.status_code = 401
      context.response.content_type = "application/json"
      context.response.print({error: "Unauthorized"}.to_json)
    end
  end

  private def extract_token(context) : String?
    auth = context.request.headers["Authorization"]?
    return nil unless auth

    if auth.starts_with?("Bearer ")
      auth[7..]
    else
      nil
    end
  end

  private def valid_token?(token : String) : Bool
    Token.valid?(token)
  end

  private def user_id_from_token(token : String) : Int64
    Token.decode(token)["user_id"].as_i64
  end
end
```

## CORS Handler

```crystal
class CorsHandler < Azu::Handler::Base
  def initialize(
    @allowed_origins = ["*"],
    @allowed_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    @allowed_headers = ["Content-Type", "Authorization"],
    @max_age = 86400
  )
  end

  def call(context)
    origin = context.request.headers["Origin"]?

    if origin && allowed_origin?(origin)
      set_cors_headers(context, origin)
    end

    # Handle preflight
    if context.request.method == "OPTIONS"
      context.response.status_code = 204
      return
    end

    call_next(context)
  end

  private def allowed_origin?(origin : String) : Bool
    @allowed_origins.includes?("*") || @allowed_origins.includes?(origin)
  end

  private def set_cors_headers(context, origin)
    headers = context.response.headers
    headers["Access-Control-Allow-Origin"] = origin
    headers["Access-Control-Allow-Methods"] = @allowed_methods.join(", ")
    headers["Access-Control-Allow-Headers"] = @allowed_headers.join(", ")
    headers["Access-Control-Max-Age"] = @max_age.to_s
  end
end
```

## Rate Limiting Handler

```crystal
class RateLimitHandler < Azu::Handler::Base
  def initialize(
    @limit = 100,
    @window = 1.minute
  )
  end

  def call(context)
    client_id = get_client_id(context)
    key = "ratelimit:#{client_id}"

    current = increment_counter(key)

    context.response.headers["X-RateLimit-Limit"] = @limit.to_s
    context.response.headers["X-RateLimit-Remaining"] = Math.max(0, @limit - current).to_s

    if current > @limit
      context.response.status_code = 429
      context.response.content_type = "application/json"
      context.response.print({error: "Too many requests"}.to_json)
      return
    end

    call_next(context)
  end

  private def get_client_id(context) : String
    context.request.headers["X-Forwarded-For"]? ||
      context.request.remote_address.to_s
  end

  private def increment_counter(key : String) : Int32
    count = Azu.cache.increment(key)
    Azu.cache.expire(key, @window) if count == 1
    count
  end
end
```

## Request ID Handler

```crystal
class RequestIdHandler < Azu::Handler::Base
  def call(context)
    request_id = context.request.headers["X-Request-ID"]? || generate_id

    # Set on request for logging
    context.request.headers["X-Request-ID"] = request_id

    # Include in response
    context.response.headers["X-Request-ID"] = request_id

    call_next(context)
  end

  private def generate_id : String
    UUID.random.to_s
  end
end
```

## Compression Handler

```crystal
class CompressionHandler < Azu::Handler::Base
  MIN_SIZE = 1024  # Only compress responses > 1KB

  def call(context)
    call_next(context)

    return unless should_compress?(context)

    body = context.response.output.to_s
    return if body.bytesize < MIN_SIZE

    compressed = Compress::Gzip.compress(body)

    context.response.headers["Content-Encoding"] = "gzip"
    context.response.output = IO::Memory.new(compressed)
  end

  private def should_compress?(context) : Bool
    accept = context.request.headers["Accept-Encoding"]?
    return false unless accept

    accept.includes?("gzip")
  end
end
```

## Conditional Handler

Skip handler based on conditions:

```crystal
class ConditionalHandler < Azu::Handler::Base
  def initialize(&@condition : HTTP::Server::Context -> Bool)
  end

  def call(context)
    if @condition.call(context)
      # Do something
    end

    call_next(context)
  end
end

# Usage
ConditionalHandler.new { |ctx| ctx.request.path.starts_with?("/api") }
```

## Handler Ordering

Order matters - handlers execute in sequence:

```crystal
MyApp.start [
  RequestIdHandler.new,       # First: Add request ID
  TimingHandler.new,          # Track timing
  CorsHandler.new,            # Handle CORS
  RateLimitHandler.new,       # Enforce limits
  AuthHandler.new,            # Authenticate
  Azu::Handler::Logger.new,   # Log requests
  Azu::Handler::Rescuer.new,  # Handle errors
  # ... endpoints
]
```

## See Also

- [Add Logging](add-logging.md)

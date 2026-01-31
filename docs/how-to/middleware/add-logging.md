# How to Add Logging

This guide shows you how to implement logging in your Azu application.

## Built-in Logger

Use Azu's built-in logger handler:

```crystal
MyApp.start [
  Azu::Handler::Logger.new,
  # ... other handlers
]
```

## Configure Log Level

Set the log level based on environment:

```crystal
Azu.configure do |config|
  case ENV.fetch("AZU_ENV", "development")
  when "production"
    config.log.level = Log::Severity::Info
  when "test"
    config.log.level = Log::Severity::Warn
  else
    config.log.level = Log::Severity::Debug
  end
end
```

## Custom Logger Handler

Create a structured logger:

```crystal
class StructuredLogger < Azu::Handler::Base
  def call(context)
    start = Time.instant
    request_id = context.request.headers["X-Request-ID"]?

    begin
      call_next(context)
    ensure
      duration = Time.instant - start
      log_request(context, duration, request_id)
    end
  end

  private def log_request(context, duration, request_id)
    Log.info { {
      request_id: request_id,
      method: context.request.method,
      path: context.request.path,
      status: context.response.status_code,
      duration_ms: duration.total_milliseconds.round(2),
      remote_ip: client_ip(context),
      user_agent: context.request.headers["User-Agent"]?
    }.to_json }
  end

  private def client_ip(context) : String
    context.request.headers["X-Forwarded-For"]?.try(&.split(",").first.strip) ||
      context.request.remote_address.to_s
  end
end
```

## Logging in Endpoints

Log within your endpoints:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    Log.debug { "Creating user with email: #{create_user_request.email}" }

    user = User.create!(create_user_request)

    Log.info { "User created: id=#{user.id}, email=#{user.email}" }

    UserResponse.new(user)
  rescue ex
    Log.error(exception: ex) { "Failed to create user" }
    raise ex
  end
end
```

## Log Backends

### File Backend

```crystal
Log.setup do |config|
  file_backend = Log::IOBackend.new(File.new("log/app.log", "a"))

  config.bind "azu.*", :info, file_backend
  config.bind "*", :info, file_backend
end
```

### JSON Backend

```crystal
class JsonLogBackend < Log::Backend
  def initialize(@io : IO = STDOUT)
  end

  def write(entry : Log::Entry)
    data = {
      timestamp: entry.timestamp.to_rfc3339,
      severity: entry.severity.to_s,
      source: entry.source,
      message: entry.message,
      data: entry.data.to_h,
    }

    if ex = entry.exception
      data = data.merge({
        exception: ex.class.name,
        exception_message: ex.message,
        backtrace: ex.backtrace?.try(&.first(10))
      })
    end

    @io.puts data.to_json
  end
end

Log.setup do |config|
  config.bind "*", :info, JsonLogBackend.new
end
```

### Multiple Backends

```crystal
Log.setup do |config|
  stdout = Log::IOBackend.new
  file = Log::IOBackend.new(File.new("log/app.log", "a"))

  # Development: stdout only
  if ENV["AZU_ENV"]? == "development"
    config.bind "*", :debug, stdout
  else
    # Production: file for all, stdout for errors
    config.bind "*", :info, file
    config.bind "*", :error, stdout
  end
end
```

## Request Context Logging

Include request context in all logs:

```crystal
class ContextLogger
  Log = ::Log.for(self)

  def self.with_context(request_id : String, user_id : Int64? = nil, &)
    Log.context.set(request_id: request_id)
    Log.context.set(user_id: user_id.to_s) if user_id

    yield
  ensure
    Log.context.clear
  end
end

# Usage in handler
class RequestContextHandler < Azu::Handler::Base
  def call(context)
    request_id = context.request.headers["X-Request-ID"]? || UUID.random.to_s
    user_id = context.request.headers["X-User-ID"]?.try(&.to_i64)

    ContextLogger.with_context(request_id, user_id) do
      call_next(context)
    end
  end
end
```

## Error Logging

Log errors with full context:

```crystal
class ErrorLogger < Azu::Handler::Base
  Log = ::Log.for(self)

  def call(context)
    call_next(context)
  rescue ex
    log_error(context, ex)
    raise ex
  end

  private def log_error(context, ex : Exception)
    Log.error(exception: ex) { {
      error: ex.class.name,
      message: ex.message,
      path: context.request.path,
      method: context.request.method,
      request_id: context.request.headers["X-Request-ID"]?
    }.to_json }
  end
end
```

## Sensitive Data Filtering

Filter sensitive data from logs:

```crystal
module LogFilter
  SENSITIVE_KEYS = ["password", "token", "secret", "api_key", "authorization"]

  def self.filter(data : Hash) : Hash
    data.transform_values do |value|
      case value
      when Hash
        filter(value)
      when String
        SENSITIVE_KEYS.any? { |k| data.keys.any?(&.downcase.includes?(k)) } ? "[FILTERED]" : value
      else
        value
      end
    end
  end
end
```

## Log Rotation

Use logrotate for production:

```
# /etc/logrotate.d/myapp
/var/log/myapp/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 appuser appuser
}
```

## Performance Logging

Log slow requests:

```crystal
class SlowRequestLogger < Azu::Handler::Base
  THRESHOLD = 1.second

  def call(context)
    start = Time.instant
    call_next(context)
    duration = Time.instant - start

    if duration > THRESHOLD
      Log.warn { "Slow request: #{context.request.method} #{context.request.path} took #{duration.total_seconds.round(2)}s" }
    end
  end
end
```

## See Also

- [Create Custom Middleware](create-custom-middleware.md)

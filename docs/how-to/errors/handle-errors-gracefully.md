# How to Handle Errors Gracefully

This guide shows you how to implement robust error handling in your Azu application.

## Built-in Error Handling

Azu provides a Rescuer handler for catching exceptions:

```crystal
MyApp.start [
  Azu::Handler::Rescuer.new,
  # ... other handlers
]
```

## HTTP Error Responses

Use built-in error responses:

```crystal
def call
  user = User.find?(params["id"])

  unless user
    raise Azu::Response::NotFound.new("/users/#{params["id"]}")
  end

  UserResponse.new(user)
end
```

Available error responses:
- `Azu::Response::BadRequest` (400)
- `Azu::Response::Unauthorized` (401)
- `Azu::Response::Forbidden` (403)
- `Azu::Response::NotFound` (404)
- `Azu::Response::ValidationError` (422)
- `Azu::Response::InternalServerError` (500)

## Custom Error Handler

Create a comprehensive error handler:

```crystal
class ErrorHandler < Azu::Handler::Base
  Log = ::Log.for(self)

  def call(context)
    call_next(context)
  rescue ex : Azu::Response::Error
    handle_known_error(context, ex)
  rescue ex : JSON::ParseException
    handle_json_error(context, ex)
  rescue ex : CQL::RecordNotFound
    handle_not_found(context, ex)
  rescue ex : CQL::RecordInvalid
    handle_validation_error(context, ex)
  rescue ex
    handle_unknown_error(context, ex)
  end

  private def handle_known_error(context, ex : Azu::Response::Error)
    respond_with_error(context, ex.status, ex.message)
  end

  private def handle_json_error(context, ex)
    respond_with_error(context, 400, "Invalid JSON: #{ex.message}")
  end

  private def handle_not_found(context, ex)
    respond_with_error(context, 404, "Resource not found")
  end

  private def handle_validation_error(context, ex)
    respond_with_error(context, 422, "Validation failed", ex.errors)
  end

  private def handle_unknown_error(context, ex)
    Log.error(exception: ex) { "Unhandled error" }

    if ENV["AZU_ENV"] == "production"
      respond_with_error(context, 500, "Internal server error")
    else
      respond_with_error(context, 500, ex.message, ex.backtrace)
    end
  end

  private def respond_with_error(context, status, message, details = nil)
    context.response.status_code = status
    context.response.content_type = "application/json"

    body = {error: message}
    body = body.merge({details: details}) if details

    context.response.print(body.to_json)
  end
end
```

## Endpoint-Level Error Handling

Handle errors within endpoints:

```crystal
struct CreateOrderEndpoint
  include Azu::Endpoint(CreateOrderRequest, OrderResponse)

  post "/orders"

  def call : Azu::Response
    validate_inventory
    order = create_order

    status 201
    OrderResponse.new(order)
  rescue ex : InsufficientInventoryError
    status 422
    ErrorResponse.new("Insufficient inventory: #{ex.message}")
  rescue ex : PaymentDeclinedError
    status 402
    ErrorResponse.new("Payment declined: #{ex.message}")
  end

  private def validate_inventory
    # Check inventory...
  end

  private def create_order
    # Create order...
  end
end
```

## Error Response Format

Create a consistent error response:

```crystal
struct ErrorResponse
  include Azu::Response

  def initialize(
    @message : String,
    @code : String? = nil,
    @details : Hash(String, String)? = nil
  )
  end

  def render
    response = {
      error: {
        message: @message
      }
    }

    response[:error][:code] = @code if @code
    response[:error][:details] = @details if @details

    response.to_json
  end
end
```

## Logging Errors

Log errors with context:

```crystal
class ErrorLogger < Azu::Handler::Base
  Log = ::Log.for(self)

  def call(context)
    call_next(context)
  rescue ex
    log_error(context, ex)
    raise ex
  end

  private def log_error(context, ex)
    Log.error(exception: ex) { {
      error_class: ex.class.name,
      message: ex.message,
      path: context.request.path,
      method: context.request.method,
      request_id: context.request.headers["X-Request-ID"]?,
      user_agent: context.request.headers["User-Agent"]?
    }.to_json }
  end
end
```

## Error Monitoring

Send errors to external monitoring:

```crystal
class ErrorReporter < Azu::Handler::Base
  def call(context)
    call_next(context)
  rescue ex
    report_error(context, ex)
    raise ex
  end

  private def report_error(context, ex)
    return if ENV["AZU_ENV"] != "production"

    # Send to Sentry, Honeybadger, etc.
    Sentry.capture_exception(ex, extra: {
      path: context.request.path,
      method: context.request.method
    })
  end
end
```

## Retry Logic

Implement retry for transient errors:

```crystal
def with_retry(max_attempts = 3, &)
  attempts = 0

  loop do
    attempts += 1
    return yield
  rescue ex : Timeout::Error | IO::Error
    raise ex if attempts >= max_attempts

    Log.warn { "Attempt #{attempts} failed, retrying..." }
    sleep (2 ** attempts).seconds
  end
end

# Usage
def call
  with_retry do
    external_api.fetch_data
  end
end
```

## Circuit Breaker

Prevent cascading failures:

```crystal
class CircuitBreaker
  enum State
    Closed
    Open
    HalfOpen
  end

  def initialize(
    @failure_threshold = 5,
    @reset_timeout = 30.seconds
  )
    @state = State::Closed
    @failures = 0
    @last_failure_time = Time.utc
  end

  def call(&)
    case @state
    when .open?
      if Time.utc - @last_failure_time > @reset_timeout
        @state = State::HalfOpen
      else
        raise CircuitOpenError.new
      end
    end

    begin
      result = yield
      on_success
      result
    rescue ex
      on_failure
      raise ex
    end
  end

  private def on_success
    @failures = 0
    @state = State::Closed
  end

  private def on_failure
    @failures += 1
    @last_failure_time = Time.utc

    if @failures >= @failure_threshold
      @state = State::Open
    end
  end
end
```

## Graceful Degradation

Provide fallback behavior:

```crystal
def call
  data = fetch_from_primary
rescue ex : ServiceUnavailableError
  Log.warn { "Primary service unavailable, using cache" }
  data = fetch_from_cache

  if data.nil?
    Log.error { "No cached data available" }
    raise ex
  end

  data
end
```

## See Also

- [Create Custom Errors](create-custom-errors.md)

# Handle errors gracefully

This guide shows you how to implement robust error handling in your Azu application.

## Built-in Error Handling

Azu provides a Rescuer handler for catching exceptions. It renders an `Azu::Response::Error` with its own status and
turns any other exception into a `500`, in the format the `Accept` header asks for (HTML, JSON, XML or plain text).
`start` without arguments already includes it:

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::Rescuer.new,
  # ... other handlers
] of HTTP::Handler
```

## HTTP Error Responses

Use built-in error responses:

```crystal
struct UserResponse
  include Azu::Response

  def render
    "user"
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    unless params["id"] == "1"
      raise Azu::Response::NotFound.new("/users/#{params["id"]}")
    end

    UserResponse.new
  end
end
```

Available error responses:
- `Azu::Response::BadRequest` (400)
- `Azu::Response::AuthenticationError` (401)
- `Azu::Response::AuthorizationError` and `Azu::Response::Forbidden` (403)
- `Azu::Response::NotFound` (404)
- `Azu::Response::ValidationError` (422)
- `Azu::Response::RateLimitError` (429)
- `Azu::Response::Error` (500 unless you give a status)

See the [Error Types Reference](../../reference/errors/error-types.md) for all of them, and for statuses that have no class
of their own.

## Custom Error Handler

Create a handler that answers errors in your own format. A handler is an `HTTP::Handler`: it calls `call_next` and
rescues what the rest of the chain raises. Put it after `Rescuer` to see errors first, or instead of it to own the
format.

A handler sees only the errors raised inside `call` (and by the handlers after it). A request that breaks its contract
never reaches `call`: the endpoint answers it itself, with `400` when the body or a field cannot be read as the
contract's types and `422` with the failing fields when a validation rule fails. Neither reaches this handler, which
sees only the final status code on the way out. Its `JSON::ParseException` and `KeyError` branches are for code in
`call` that parses JSON or reads `params["name"]` itself:

```crystal
class ErrorHandler
  include HTTP::Handler

  Log = ::Log.for(self)

  def call(context : HTTP::Server::Context)
    call_next(context)
  rescue ex : Azu::Response::Error
    respond_with_error(context, ex.status_code, ex.detail, ex.errors)
  rescue ex : JSON::ParseException
    respond_with_error(context, 400, "Invalid JSON: #{ex.message}")
  rescue ex : KeyError
    respond_with_error(context, 400, ex.message || "Missing parameter")
  rescue ex
    handle_unknown_error(context, ex)
  end

  private def handle_unknown_error(context : HTTP::Server::Context, ex : Exception)
    Log.error(exception: ex) { "Unhandled error" }

    if Azu.current_config.env.production?
      respond_with_error(context, 500, "Internal server error")
    else
      respond_with_error(context, 500, ex.message || "Error", ex.backtrace)
    end
  end

  private def respond_with_error(context : HTTP::Server::Context, status : Int32, message : String, details : Array(String) = [] of String)
    context.response.status_code = status
    context.response.content_type = "application/json"

    body = {error: message, details: details}

    context.response.print(body.to_json)
  end
end
```

## Endpoint-Level Error Handling

Handle errors within endpoints:

```crystal
class InsufficientInventoryError < Exception
end

class PaymentDeclinedError < Exception
end

struct ErrorResponse
  include Azu::Response

  def initialize(@message : String)
  end

  def render
    {error: @message}.to_json
  end
end

struct OrderResponse
  include Azu::Response

  def render
    {status: "created"}.to_json
  end
end

struct CreateOrderEndpoint
  include Azu::Endpoint(Azu::Request, OrderResponse | ErrorResponse)

  post "/orders"

  def call : OrderResponse | ErrorResponse
    validate_inventory
    create_order

    status 201
    OrderResponse.new
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

When an endpoint can answer with more than one response type, declare the union as its response type, as above.
For failures, raising an `Azu::Response::Error` subclass is usually simpler: the status and body come from the error.

## Error Response Format

Create a consistent error response:

```crystal
struct ApiErrorResponse
  include Azu::Response

  def initialize(
    @message : String,
    @code : String? = nil,
    @details : Hash(String, String)? = nil,
  )
  end

  def render
    error = {} of String => (String | Hash(String, String))
    error["message"] = @message
    error["code"] = @code.not_nil! if @code
    error["details"] = @details.not_nil! if @details

    {error: error}.to_json
  end
end
```

## Logging Errors

Log errors with context:

```crystal
class ErrorLogger
  include HTTP::Handler

  Log = ::Log.for(self)

  def call(context : HTTP::Server::Context)
    call_next(context)
  rescue ex
    log_error(context, ex)
    raise ex
  end

  private def log_error(context : HTTP::Server::Context, ex : Exception)
    Log.error(exception: ex) {
      {
        error_class: ex.class.name,
        message:     ex.message,
        path:        context.request.path,
        method:      context.request.method,
        request_id:  context.request.headers["X-Request-ID"]?,
        user_agent:  context.request.headers["User-Agent"]?,
      }.to_json
    }
  end
end
```

Put it after `Rescuer` in the handler list so it sees the exception before `Rescuer` turns it into a response.

## Error Monitoring

Send errors to external monitoring. The `ExternalTracker` module below stands in for your tracker's SDK (Sentry,
Honeybadger, ...):

```crystal
module ExternalTracker
  def self.capture(ex : Exception, extra : Hash(String, String)) : Nil
  end
end

class ErrorReporter
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    call_next(context)
  rescue ex
    report_error(context, ex)
    raise ex
  end

  private def report_error(context : HTTP::Server::Context, ex : Exception)
    return unless Azu.current_config.env.production?

    ExternalTracker.capture(ex, {
      "path"   => context.request.path,
      "method" => context.request.method,
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
  rescue ex : IO::TimeoutError | IO::Error
    raise ex if attempts >= max_attempts

    Log.for("retry").warn { "Attempt #{attempts} failed, retrying..." }
    sleep (2 ** attempts).seconds
  end
end

struct DataResponse
  include Azu::Response

  def initialize(@data : String)
  end

  def render
    @data
  end
end

struct FetchEndpoint
  include Azu::Endpoint(Azu::Request, DataResponse)

  get "/fetch"

  def call : DataResponse
    data = with_retry do
      fetch_data
    end
    DataResponse.new(data)
  end

  private def fetch_data : String
    "data"
  end
end
```

## Circuit Breaker

Prevent cascading failures:

```crystal
class CircuitOpenError < Azu::Response::Error
  def initialize
    super(
      title: "Service Unavailable",
      status: HTTP::Status::SERVICE_UNAVAILABLE,
      errors: [] of String
    )
    @detail = "The circuit is open; try again later"
  end
end

class CircuitBreaker
  enum State
    Closed
    Open
    HalfOpen
  end

  def initialize(
    @failure_threshold = 5,
    @reset_timeout = 30.seconds,
  )
    @state = State::Closed
    @failures = 0
    @last_failure_time = Time.utc
    @lock = Mutex.new
  end

  def call(&)
    @lock.synchronize do
      if @state.open?
        raise CircuitOpenError.new unless Time.utc - @last_failure_time > @reset_timeout
        @state = State::HalfOpen
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
    @lock.synchronize do
      @failures = 0
      @state = State::Closed
    end
  end

  private def on_failure
    @lock.synchronize do
      @failures += 1
      @last_failure_time = Time.utc
      @state = State::Open if @failures >= @failure_threshold
    end
  end
end
```

A `CircuitOpenError` is an `Azu::Response::Error`, so `Rescuer` answers it with a `503` without more code.

## Graceful Degradation

Provide fallback behavior:

```crystal
class ServiceUnavailableError < Exception
end

struct ProfileResponse
  include Azu::Response

  def initialize(@data : String)
  end

  def render
    @data
  end
end

struct ProfileEndpoint
  include Azu::Endpoint(Azu::Request, ProfileResponse)

  get "/profile"

  def call : ProfileResponse
    ProfileResponse.new(fetch_from_primary)
  rescue ex : ServiceUnavailableError
    Log.for("profile").warn { "Primary service unavailable, using cache" }

    unless data = fetch_from_cache
      Log.for("profile").error { "No cached data available" }
      raise ex
    end

    ProfileResponse.new(data)
  end

  private def fetch_from_primary : String
    raise ServiceUnavailableError.new("primary is down")
  end

  private def fetch_from_cache : String?
    Azu.cache.get("profile")
  end
end
```

## See Also

- [Create Custom Errors](create-custom-errors.md)

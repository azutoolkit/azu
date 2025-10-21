# Errors API

Azu provides a comprehensive error handling system with type-safe error responses, automatic error recovery, and development-friendly error pages.

## Azu::Response::Error

Base class for all Azu errors.

### Properties

- `message : String` - Error message
- `status_code : Int32` - HTTP status code
- `details : Hash(String, String)` - Additional error details

### Methods

#### `initialize(message : String, status_code : Int32 = 500, details : Hash(String, String) = {} of String => String)`

Create a new error with message, status code, and optional details.

```crystal
error = Azu::Response::Error.new("User not found", 404)
```

#### `to_json : String`

Convert error to JSON format.

```crystal
error = Azu::Response::Error.new("Invalid input", 400)
json = error.to_json
# {"error": "Invalid input", "status": 400}
```

## Built-in Error Types

### Azu::Response::BadRequest

400 Bad Request error.

```crystal
raise Azu::Response::BadRequest.new("Invalid request parameters")
```

### Azu::Response::Unauthorized

401 Unauthorized error.

```crystal
raise Azu::Response::Unauthorized.new("Authentication required")
```

### Azu::Response::Forbidden

403 Forbidden error.

```crystal
raise Azu::Response::Forbidden.new("Access denied")
```

### Azu::Response::NotFound

404 Not Found error.

```crystal
raise Azu::Response::NotFound.new("Resource not found")
```

### Azu::Response::MethodNotAllowed

405 Method Not Allowed error.

```crystal
raise Azu::Response::MethodNotAllowed.new("GET method not allowed")
```

### Azu::Response::Conflict

409 Conflict error.

```crystal
raise Azu::Response::Conflict.new("Resource already exists")
```

### Azu::Response::UnprocessableEntity

422 Unprocessable Entity error.

```crystal
raise Azu::Response::UnprocessableEntity.new("Validation failed")
```

### Azu::Response::InternalServerError

500 Internal Server Error.

```crystal
raise Azu::Response::InternalServerError.new("Something went wrong")
```

## Custom Error Classes

### Basic Custom Error

```crystal
class ValidationError < Azu::Response::Error
  def initialize(message : String, field : String)
    super(message, 422, {"field" => field})
  end
end
```

### Error with Context

```crystal
class BusinessLogicError < Azu::Response::Error
  def initialize(message : String, context : Hash(String, String))
    super(message, 400, context)
  end
end
```

### Error with Stack Trace

```crystal
class DevelopmentError < Azu::Response::Error
  def initialize(message : String, exception : Exception)
    super(message, 500, {"stack_trace" => exception.backtrace.join("\n")})
  end
end
```

## Error Handling in Endpoints

### Basic Error Handling

```crystal
struct UserEndpoint
  include Azu::Endpoint

  get "/users/:id"

  def call
    user_id = request.param("id")

    begin
      user = find_user(user_id)
      response.body(user.to_json)
    rescue NotFoundError
      raise Azu::Response::NotFound.new("User not found")
    rescue ValidationError => e
      raise Azu::Response::BadRequest.new(e.message)
    end
  end
end
```

### Error with Details

```crystal
def call
  begin
    validate_input(request.body)
    process_request
  rescue ValidationError => e
    raise Azu::Response::UnprocessableEntity.new(
      "Validation failed",
      {"errors" => e.errors.to_json}
    )
  end
end
```

### Error Recovery

```crystal
def call
  begin
    risky_operation
  rescue NetworkError
    # Retry with exponential backoff
    retry_with_backoff
  rescue DatabaseError
    # Fallback to cached data
    use_cached_data
  end
end
```

## Error Middleware

### Automatic Error Handling

```crystal
class ErrorHandler < Azu::Handler::Base
  def call(request, response)
    begin
      yield
    rescue Azu::Response::Error => e
      handle_azu_error(e, response)
    rescue Exception => e
      handle_generic_error(e, response)
    end
  end

  private def handle_azu_error(error, response)
    response.status(error.status_code)
    response.header("Content-Type", "application/json")
    response.body(error.to_json)
  end

  private def handle_generic_error(error, response)
    if Azu::Environment.development?
      response.status(500)
      response.body(error.inspect)
    else
      response.status(500)
      response.body("Internal Server Error")
    end
  end
end
```

### Error Logging

```crystal
class ErrorLogger < Azu::Handler::Base
  def call(request, response)
    begin
      yield
    rescue Exception => e
      log_error(e, request)
      raise
    end
  end

  private def log_error(error, request)
    Azu.logger.error do
      "Error: #{error.message}\n" +
      "Request: #{request.method} #{request.path}\n" +
      "Backtrace: #{error.backtrace.join("\n")}"
    end
  end
end
```

## Error Responses

### JSON Error Response

```crystal
def handle_error(error, response)
  response.status(error.status_code)
  response.header("Content-Type", "application/json")
  response.body({
    "error" => error.message,
    "status" => error.status_code,
    "details" => error.details
  }.to_json)
end
```

### HTML Error Response

```crystal
def handle_error(error, response)
  response.status(error.status_code)
  response.header("Content-Type", "text/html")

  html = <<-HTML
    <!DOCTYPE html>
    <html>
      <head>
        <title>Error #{error.status_code}</title>
      </head>
      <body>
        <h1>Error #{error.status_code}</h1>
        <p>#{error.message}</p>
      </body>
    </html>
  HTML

  response.body(html)
end
```

### Error Page Template

```crystal
def handle_error(error, response)
  response.status(error.status_code)
  response.header("Content-Type", "text/html")

  template = Azu::Templates.render("error.html", {
    "error_code" => error.status_code,
    "error_message" => error.message,
    "error_details" => error.details
  })

  response.body(template)
end
```

## Error Validation

### Input Validation

```crystal
class ValidationError < Azu::Response::Error
  def initialize(errors : Hash(String, Array(String)))
    super("Validation failed", 422, {"errors" => errors.to_json})
  end
end

def validate_user_input(data)
  errors = {} of String => Array(String)

  if data["name"]?.nil? || data["name"].empty?
    errors["name"] = ["Name is required"]
  end

  if data["email"]?.nil? || !valid_email?(data["email"])
    errors["email"] = ["Valid email is required"]
  end

  raise ValidationError.new(errors) unless errors.empty?
end
```

### Business Logic Validation

```crystal
def validate_business_rules(user, action)
  case action
  when "delete"
    raise Azu::Response::Forbidden.new("Cannot delete admin user") if user.admin?
  when "update"
    raise Azu::Response::Conflict.new("Email already exists") if email_exists?(user.email)
  end
end
```

## Error Testing

### Unit Testing

```crystal
describe "Error Handling" do
  it "raises correct error for invalid input" do
    expect_raises(Azu::Response::BadRequest) do
      validate_input("invalid")
    end
  end

  it "handles custom errors correctly" do
    error = ValidationError.new("Invalid email", "email")
    expect(error.status_code).to eq(422)
    expect(error.message).to eq("Invalid email")
  end
end
```

### Integration Testing

```crystal
describe "Error Endpoints" do
  it "returns 404 for non-existent resource" do
    response = get("/users/999")
    expect(response.status).to eq(404)
    expect(response.body).to contain("User not found")
  end

  it "returns 422 for validation errors" do
    response = post("/users", {"name" => ""})
    expect(response.status).to eq(422)
    expect(response.body).to contain("Validation failed")
  end
end
```

## Error Monitoring

### Error Tracking

```crystal
class ErrorTracker < Azu::Handler::Base
  def call(request, response)
    begin
      yield
    rescue Exception => e
      track_error(e, request)
      raise
    end
  end

  private def track_error(error, request)
    # Send to error tracking service
    ErrorTrackingService.track(
      error: error,
      request: request,
      timestamp: Time.utc
    )
  end
end
```

### Error Metrics

```crystal
class ErrorMetrics < Azu::Handler::Base
  def initialize
    @error_counts = {} of String => Int32
  end

  def call(request, response)
    begin
      yield
    rescue Exception => e
      increment_error_count(e.class.name)
      raise
    end
  end

  private def increment_error_count(error_type)
    @error_counts[error_type] ||= 0
    @error_counts[error_type] += 1
  end
end
```

## Error Recovery Strategies

### Retry Logic

```crystal
def call_with_retry(max_attempts = 3)
  attempts = 0

  begin
    yield
  rescue TemporaryError => e
    attempts += 1
    if attempts < max_attempts
      sleep(2 ** attempts)  # Exponential backoff
      retry
    else
      raise Azu::Response::ServiceUnavailable.new("Service temporarily unavailable")
    end
  end
end
```

### Fallback Responses

```crystal
def call_with_fallback
  begin
    yield
  rescue DatabaseError
    # Return cached data
    response.body(cached_data.to_json)
  rescue ExternalServiceError
    # Return default response
    response.body(default_response.to_json)
  end
end
```

## Next Steps

- Learn about [Performance Optimization](performance.md)
- Explore [Monitoring and Logging](monitoring.md)
- Understand [Security Best Practices](security.md)
- See [Testing Strategies](testing.md)

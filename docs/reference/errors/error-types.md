# Error Types Reference

Complete reference for Azu's built-in error types.

## Base Error Class

### Azu::Response::Error

Base class for all HTTP errors.

```crystal
class Azu::Response::Error < Exception
  getter status : Int32
  getter message : String
  getter context : ErrorContext?

  def initialize(@message : String, @status : Int32 = 500, @context : ErrorContext? = nil)
  end
end
```

**Properties:**
- `status : Int32` - HTTP status code
- `message : String` - Error message
- `context : ErrorContext?` - Additional context

## Client Errors (4xx)

### BadRequest (400)

Invalid request from client.

```crystal
raise Azu::Response::BadRequest.new("Invalid JSON")
raise Azu::Response::BadRequest.new("Missing required field: email")
```

**Usage:** Malformed requests, invalid data formats

### Unauthorized (401)

Authentication required.

```crystal
raise Azu::Response::Unauthorized.new
raise Azu::Response::Unauthorized.new("Invalid token")
```

**Usage:** Missing or invalid authentication

### Forbidden (403)

Access denied despite authentication.

```crystal
raise Azu::Response::Forbidden.new
raise Azu::Response::Forbidden.new("Admin access required")
```

**Usage:** Authenticated but not authorized

### NotFound (404)

Resource not found.

```crystal
raise Azu::Response::NotFound.new("/users/123")
raise Azu::Response::NotFound.new("User not found")
```

**Usage:** Resource doesn't exist

### MethodNotAllowed (405)

HTTP method not supported.

```crystal
raise Azu::Response::MethodNotAllowed.new(["GET", "POST"])
```

**Usage:** Wrong HTTP method for endpoint

### Conflict (409)

Request conflicts with current state.

```crystal
raise Azu::Response::Conflict.new("Email already registered")
raise Azu::Response::Conflict.new("Resource version mismatch")
```

**Usage:** Duplicate records, version conflicts

### Gone (410)

Resource permanently deleted.

```crystal
raise Azu::Response::Gone.new("This API endpoint has been removed")
```

**Usage:** Deprecated resources

### UnprocessableEntity (422)

Validation failed.

```crystal
raise Azu::Response::UnprocessableEntity.new("Validation failed")
```

**Usage:** Invalid but well-formed requests

### ValidationError (422)

Validation error with details.

```crystal
raise Azu::Response::ValidationError.new([
  {field: "email", message: "is invalid"},
  {field: "name", message: "is required"}
])
```

**Properties:**
- `errors : Array(NamedTuple(field: String, message: String))`

**JSON Response:**
```json
{
  "error": "Validation failed",
  "details": [
    {"field": "email", "message": "is invalid"},
    {"field": "name", "message": "is required"}
  ]
}
```

### TooManyRequests (429)

Rate limit exceeded.

```crystal
raise Azu::Response::TooManyRequests.new
raise Azu::Response::TooManyRequests.new("Rate limit exceeded. Try again in 60 seconds.")
```

**Usage:** Rate limiting

## Server Errors (5xx)

### InternalServerError (500)

Unexpected server error.

```crystal
raise Azu::Response::InternalServerError.new
raise Azu::Response::InternalServerError.new("Database connection failed")
```

**Usage:** Unhandled exceptions

### NotImplemented (501)

Feature not implemented.

```crystal
raise Azu::Response::NotImplemented.new("This feature is coming soon")
```

**Usage:** Placeholder for future features

### BadGateway (502)

Invalid response from upstream.

```crystal
raise Azu::Response::BadGateway.new("Payment gateway error")
```

**Usage:** Proxy/gateway errors

### ServiceUnavailable (503)

Service temporarily unavailable.

```crystal
raise Azu::Response::ServiceUnavailable.new("Database maintenance in progress")
raise Azu::Response::ServiceUnavailable.new("High traffic, please retry")
```

**Usage:** Maintenance, overload

### GatewayTimeout (504)

Upstream timeout.

```crystal
raise Azu::Response::GatewayTimeout.new("Payment service timeout")
```

**Usage:** External service timeouts

## ErrorContext

Additional context for debugging.

```crystal
struct ErrorContext
  property request_id : String?
  property path : String?
  property method : String?
  property user_id : Int64?
  property timestamp : Time

  def self.from_http_context(context : HTTP::Server::Context, request_id : String? = nil)
    new(
      request_id: request_id,
      path: context.request.path,
      method: context.request.method,
      timestamp: Time.utc
    )
  end
end
```

## Creating Custom Errors

```crystal
class InsufficientFundsError < Azu::Response::Error
  getter required : Float64
  getter available : Float64

  def initialize(@required : Float64, @available : Float64)
    super("Insufficient funds: need $#{@required}, have $#{@available}", 422)
  end
end

class RateLimitError < Azu::Response::Error
  getter retry_after : Int32

  def initialize(@retry_after : Int32)
    super("Rate limit exceeded", 429)
  end

  def headers : Hash(String, String)
    {"Retry-After" => @retry_after.to_s}
  end
end
```

## Error Response Format

Default JSON format:

```json
{
  "error": "Error message here"
}
```

With details:

```json
{
  "error": "Validation failed",
  "details": [
    {"field": "email", "message": "is invalid"}
  ]
}
```

Development mode:

```json
{
  "error": "Error message",
  "backtrace": ["file.cr:10", "file.cr:5"]
}
```

## HTTP Status Codes Summary

| Code | Name | Class |
|------|------|-------|
| 400 | Bad Request | `BadRequest` |
| 401 | Unauthorized | `Unauthorized` |
| 403 | Forbidden | `Forbidden` |
| 404 | Not Found | `NotFound` |
| 405 | Method Not Allowed | `MethodNotAllowed` |
| 409 | Conflict | `Conflict` |
| 410 | Gone | `Gone` |
| 422 | Unprocessable Entity | `UnprocessableEntity` |
| 429 | Too Many Requests | `TooManyRequests` |
| 500 | Internal Server Error | `InternalServerError` |
| 501 | Not Implemented | `NotImplemented` |
| 502 | Bad Gateway | `BadGateway` |
| 503 | Service Unavailable | `ServiceUnavailable` |
| 504 | Gateway Timeout | `GatewayTimeout` |

## See Also

- [How to Handle Errors Gracefully](../../how-to/errors/handle-errors-gracefully.md)
- [How to Create Custom Errors](../../how-to/errors/create-custom-errors.md)

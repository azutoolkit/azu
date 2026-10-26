# Error types

Complete reference for Azu's built-in error types.

## Base Error Class

### Azu::Response::Error

Base class for all HTTP errors. It is an `Exception` and an `Azu::Response`. Raise it from an endpoint and
`Azu::Handler::Rescuer` writes it to the client with its status.

```crystal
error = Azu::Response::Error.new("Payment failed", HTTP::Status::BAD_REQUEST, ["card declined"])
error.status_code # => 400
error.title       # => "Payment failed"
```

**Properties:**
- `status : HTTP::Status` - HTTP status (`status_code` is the number)
- `title : String` - Short title
- `detail : String` - Longer explanation
- `source : String` - What the error is about, such as a path
- `errors : Array(String)` - Individual messages
- `context : ErrorContext?` - Additional context
- `error_id : String` - Unique id of this error, sent as `X-Error-ID`
- `fingerprint : String` - Stable hash of class, title, detail and source, sent as `X-Error-Fingerprint`

## Client Errors (4xx)

### BadRequest (400)

Invalid request from client. Also raised when a request body cannot be parsed into the request type.

```crystal
raise Azu::Response::BadRequest.new("Invalid JSON")
raise Azu::Response::BadRequest.new("Missing required field: email")
```

**Usage:** Malformed requests, invalid data formats

### AuthenticationError (401)

Authentication required.

```crystal
raise Azu::Response::AuthenticationError.new
raise Azu::Response::AuthenticationError.new("Invalid token")
```

**Usage:** Missing or invalid authentication

### AuthorizationError (403)

Access denied despite authentication.

```crystal
raise Azu::Response::AuthorizationError.new
raise Azu::Response::AuthorizationError.new("Admin access required")
```

**Usage:** Authenticated but not authorized

### Forbidden (403)

An `AuthorizationError` with a fixed message, "The server understood the request but refuses to authorize it."

```crystal
raise Azu::Response::Forbidden.new
```

### NotFound (404)

Resource not found. The argument is the path, which is kept in `source`.

```crystal
raise Azu::Response::NotFound.new("/users/123")
```

**Usage:** Resource doesn't exist. The router answers paths no route matches with it (it writes the error itself,
without raising it).

### TimeoutError (408)

```crystal
raise Azu::Response::TimeoutError.new("Upstream did not answer in time")
```

### PayloadTooLarge (413)

The request body is larger than the server accepts. Raised for bodies and uploads over the configured limits.

```crystal
raise Azu::Response::PayloadTooLarge.new
```

### ValidationError (422)

Validation error with the failing fields. When a request breaks a validation rule of its contract, the endpoint
answers this `422` itself before `call` runs, so neither `Rescuer` nor the router is involved and a handler that
rescues `ValidationError` never sees it. Raise it yourself inside `call` for checks the contract cannot express.

```crystal
raise Azu::Response::ValidationError.new({
  "email" => ["is invalid"],
  "name"  => ["is required"],
})

raise Azu::Response::ValidationError.new("email", "is invalid")
```

**Properties:**
- `field_errors : Hash(String, Array(String))`
- `add_field_error(field, message)` adds one more

**JSON Response** (an RFC 7807 problem document, sent as `application/problem+json` when the request's `Accept` names it and as `application/json` otherwise):

```json
{
  "type": "about:blank",
  "title": "Validation Error",
  "status": 422,
  "detail": "The request could not be processed due to validation errors.",
  "errors": {
    "email": ["is invalid"],
    "name": ["is required"]
  }
}
```

With `config.error_format = Azu::ErrorFormat::Legacy` the body is PascalCase (`FieldErrors`, `ErrorId`,
`Fingerprint`, ...).

### RateLimitError (429)

Rate limit exceeded. When `retry_after` (seconds) is given, the response carries a `Retry-After` header.

```crystal
raise Azu::Response::RateLimitError.new
raise Azu::Response::RateLimitError.new(60)
```

**Usage:** Rate limiting

## Server Errors (5xx)

### DatabaseError (500)

```crystal
raise Azu::Response::DatabaseError.new
raise Azu::Response::DatabaseError.new("Database connection failed")
```

**Usage:** Failed database operations. Unhandled exceptions are turned into a generic 500 `Error` by `Rescuer`.

### ExternalServiceError (502)

A service this one depends on failed. The first argument is the service name.

```crystal
raise Azu::Response::ExternalServiceError.new("Payments", "Payment gateway error")
```

**Usage:** Proxy/gateway errors, failing third-party APIs

## Statuses Without a Class

There is no class for 405, 409, 410, 501, 503 and 504. Build an `Azu::Response::Error` with the status, or define a
subclass (see [Creating Custom Errors](#creating-custom-errors)):

```crystal
raise Azu::Response::Error.new("Conflict", HTTP::Status::CONFLICT, ["Email already registered"])
raise Azu::Response::Error.new("Service Unavailable", HTTP::Status::SERVICE_UNAVAILABLE, [] of String)
```

Inside an endpoint, `error("Email already registered", 409)` builds the same object.

## ErrorContext

`Azu::ErrorContext` carries request details for debugging. Every field is optional.

```crystal
context = Azu::ErrorContext.new(request_id: "req-123", user_id: "42")
raise Azu::Response::Forbidden.new(context)
```

**Properties:** `timestamp`, `request_id`, `user_id`, `session_id`, `ip_address`, `user_agent`, `referer`,
`endpoint`, `method`, `params` and `headers`.

`ErrorContext.from_http_context(context, request_id)` fills the request fields from an `HTTP::Server::Context`.
Context is shown to clients only in the development environment.

## Creating Custom Errors

Subclass `Azu::Response::Error`, pass the title, status and messages to `super`, and set `detail` for the explanation:

```crystal
class InsufficientFundsError < Azu::Response::Error
  getter required : Float64
  getter available : Float64

  def initialize(@required : Float64, @available : Float64)
    super(
      title: "Insufficient Funds",
      status: HTTP::Status::UNPROCESSABLE_ENTITY,
      errors: [] of String
    )
    @detail = "Insufficient funds: need $#{@required}, have $#{@available}"
  end
end

class ConflictError < Azu::Response::Error
  def initialize(detail : String)
    super(title: "Conflict", status: HTTP::Status::CONFLICT, errors: [] of String)
    @detail = detail
  end
end

raise InsufficientFundsError.new(100.0, 25.0)
```

## Error Response Format

`Rescuer` (and the router, for an unrouted path, and the endpoint, for a broken contract) writes an error in the
format the first entry of the `Accept` header asks for: HTML (an error page), JSON, XML or plain text. With no
`Accept`, or `*/*`, the body is plain text. The JSON body is an RFC 7807 problem document, the same shape the `422`
of a broken request contract uses, and it is the same for every JSON client (see the `Content-Type` note below):

```json
{
  "type": "about:blank",
  "title": "Insufficient Funds",
  "status": 422,
  "detail": "Insufficient funds: need $100.0, have $25.0",
  "errors": [],
  "error_id": "4f2a..."
}
```

- `instance` is the request path (set when the error is written for a request) and never the error's own `source`.
- `title` is the error's own title, not always the status phrase; `status` and `detail` tell the rest.
- `Content-Type` is `application/problem+json` for a client whose `Accept` names it, `application/json` for any other JSON client (the body is the same).
- `errors` is a list of messages here; a `ValidationError` (and the contract `422`) puts an object of field name to
  messages there.
- `error_id` is the value of the `X-Error-ID` response header.
- In development `context` and `backtrace` are added. Production bodies never carry them.
- `error_format = Legacy` writes a PascalCase body (`Status`, `Link`, `Title`, `Detail`, `Source`, `Errors`,
  `ErrorId`, `Fingerprint`, `Context`, `Backtrace`, `Timestamp`) as `application/json`, for validation failures and for
  every other error.

## HTTP Status Codes Summary

| Code | Name | Class |
|------|------|-------|
| 400 | Bad Request | `BadRequest` |
| 401 | Unauthorized | `AuthenticationError` |
| 403 | Forbidden | `AuthorizationError`, `Forbidden` |
| 404 | Not Found | `NotFound` |
| 406 | Not Acceptable | `NotAcceptable` |
| 408 | Request Timeout | `TimeoutError` |
| 413 | Payload Too Large | `PayloadTooLarge` |
| 422 | Unprocessable Entity | `ValidationError` |
| 429 | Too Many Requests | `RateLimitError` |
| 500 | Internal Server Error | `Error`, `DatabaseError` |
| 502 | Bad Gateway | `ExternalServiceError` |

## See Also

- [How to Handle Errors Gracefully](../../how-to/errors/handle-errors-gracefully.md)
- [How to Create Custom Errors](../../how-to/errors/create-custom-errors.md)

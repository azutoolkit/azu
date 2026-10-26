---
description: "Response objects define how endpoint results are rendered to clients: built-in types, errors, headers and status."
---

# Response

## Including Response

```crystal
struct MyResponse
  include Azu::Response

  def initialize(@data : Hash(String, String))
  end

  def render
    @data.to_json
  end
end
```

## Required methods

### render

Return the response body as a string.

```crystal
struct UserNameResponse
  include Azu::Response

  def initialize(@id : Int64, @name : String)
  end

  def render : String
    {id: @id, name: @name}.to_json
  end
end
```

**Returns:** `String`

## Built-in response types

Azu ships these response types:

- `Azu::Response::Empty`, for an endpoint that sends no body (below);
- the `Azu::Response::Negotiable` module, which renders one response as HTML, JSON, XML or text by the `Accept`
  header, and answers `Azu::Response::NotAcceptable` (406) when none fits: see [Content negotiation](content-negotiation.md);
- `Azu::Response::Stream` and `Azu::Response::EventStream`, which write a chunked body or server-sent events while
  the endpoint runs: see [Streaming and server-sent events](streaming.md).

Anything else is a response struct of your own that includes `Azu::Response`; set the content type in the endpoint
with `content_type`.

### JSON, text and HTML

The body is whatever `render` returns, and the endpoint sets the content type:

```crystal
struct DataResponse
  include Azu::Response

  def initialize(@message : String, @count : Int32)
  end

  def render
    {message: @message, count: @count}.to_json
  end
end

struct DataEndpoint
  include Azu::Endpoint(Azu::Request, DataResponse)

  get "/data"

  def call : DataResponse
    content_type "application/json"
    DataResponse.new("Hello", 42)
  end
end

struct TextResponse
  include Azu::Response

  def initialize(@text : String)
  end

  def render
    @text
  end
end

struct HealthEndpoint
  include Azu::Endpoint(Azu::Request, TextResponse)

  get "/health"

  def call : TextResponse
    content_type "text/plain"
    TextResponse.new("OK")
  end
end

struct PageEndpoint
  include Azu::Endpoint(Azu::Request, TextResponse)

  get "/page"

  def call : TextResponse
    content_type "text/html"
    TextResponse.new("<h1>Welcome</h1>")
  end
end
```

For HTML pages rendered from templates, include `Azu::Templates::Renderable` in the response and call
`view "users/show.html", {...}`.

### Azu::Response::Empty

A response with no body. Set the status in the endpoint.

```crystal
struct DeleteEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  delete "/items/:id"

  def call : Azu::Response::Empty
    status 204
    Azu::Response::Empty.new
  end
end
```

## Error responses

### Azu::Response::Error

Base class for error responses. It is an `Exception` and an `Azu::Response`. Raise it, or one of its subclasses, from
an endpoint and `Azu::Handler::Rescuer` renders it with the status and in the format the `Accept` header asks for
(HTML, JSON, XML or plain text).

Properties are `status`, `title`, `detail`, `source`, `errors`, `context`, `error_id` and `fingerprint`;
`status_code` is the numeric status.

```crystal
error = Azu::Response::Error.new("Payment failed", HTTP::Status::BAD_REQUEST, ["card declined"])
error.status_code # => 400
error.detail      # => "Payment failed"
```

### Built-in errors

| Class | Status | Usage |
|-------|--------|-------|
| `BadRequest` | 400 | Invalid request, or a body that cannot be parsed |
| `AuthenticationError` | 401 | Authentication required |
| `AuthorizationError` | 403 | Insufficient permissions |
| `Forbidden` | 403 | Access denied (an `AuthorizationError`) |
| `NotFound` | 404 | Resource not found |
| `NotAcceptable` | 406 | The client accepts none of the formats a [negotiated response](content-negotiation.md) renders (the body lists them in `supported`) |
| `TimeoutError` | 408 | Request timeout |
| `PayloadTooLarge` | 413 | Request body too large |
| `ValidationError` | 422 | Request contract broken |
| `RateLimitError` | 429 | Rate limit exceeded (sends `Retry-After`) |
| `DatabaseError` | 500 | Database operation failed |
| `ExternalServiceError` | 502 | A service this one depends on is unavailable |

### Using error responses

```crystal
struct FindUserEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/users/:id"

  def call : Azu::Response::Empty
    id = params["id"]
    raise Azu::Response::NotFound.new("/users/#{id}") if id == "0"

    raise Azu::Response::AuthenticationError.new unless header["Authorization"]?

    Azu::Response::Empty.new
  end
end
```

### ValidationError

Answers `422` with the failing fields. When a request breaks a validation rule of its contract, the endpoint
answers this `422` itself before `call` runs (neither `Rescuer` nor the router is involved, and a handler that
rescues `ValidationError` never sees it). Raise it yourself inside `call` for checks the contract cannot express;
`Rescuer` renders that one.

```crystal
raise Azu::Response::ValidationError.new({
  "email" => ["is invalid"],
  "name"  => ["is required"],
})

raise Azu::Response::ValidationError.new("email", "is invalid")
```

By default the body is an RFC 7807 problem document (`Content-Type: application/problem+json` for a client that names it in `Accept`, `application/json` otherwise):

```json
{"type": "about:blank", "title": "Validation Error", "status": 422,
 "detail": "The request could not be processed due to validation errors.",
 "errors": {"email": ["is invalid"], "name": ["is required"]}}
```

Every other `Response::Error` (a `404` from the router, `BadRequest`, `AuthenticationError`, an unhandled exception
turned into a `500`, ...) answers JSON clients with the same envelope, `errors` being a list of messages (the
`Content-Type` is `application/problem+json` for a client that names it in `Accept`, `application/json` otherwise): see [Error Types](../errors/error-types.md#error-response-format).

With `config.error_format = Azu::ErrorFormat::Legacy` the bodies are PascalCase instead (`FieldErrors`, `ErrorId`, ...
for a validation failure), sent as `application/json`.

## Response with headers

Set custom headers in your endpoint with `header key, value`:

```crystal
struct MyResponse
  include Azu::Response

  def render
    "data"
  end
end

struct CachedEndpoint
  include Azu::Endpoint(Azu::Request, MyResponse)

  get "/cached"

  def call : MyResponse
    header "X-Custom-Header", "value"
    header "Cache-Control", "max-age=3600"

    MyResponse.new
  end
end
```

## Response with status

Set custom status codes:

```crystal
struct MyResponse
  include Azu::Response

  def render
    "data"
  end
end

struct CreateTaskEndpoint
  include Azu::Endpoint(Azu::Request, MyResponse)

  post "/tasks"

  def call : MyResponse
    status 201 # Created
    MyResponse.new
  end
end

struct QueueTaskEndpoint
  include Azu::Endpoint(Azu::Request, MyResponse)

  post "/queue"

  def call : MyResponse
    status 202 # Accepted
    MyResponse.new
  end
end
```

## Streaming responses

For large responses, write to the HTTP response from the endpoint and return `Azu::Response::Empty`:

```crystal
struct StreamEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/stream"

  def call : Azu::Response::Empty
    out = context.response
    out.content_type = "application/json"

    out.print "["
    3.times do |i|
      out.print "," if i > 0
      out.print({id: i}.to_json)
      out.flush
    end
    out.print "]"

    Azu::Response::Empty.new
  end
end
```

## Content negotiation

Errors are negotiated for you from the `Accept` header. For your own responses, read the header in the endpoint and
let the response choose the format:

```crystal
struct NegotiatedResponse
  include Azu::Response

  def initialize(@data : Hash(String, String), @accept : String)
  end

  def render
    case @accept
    when "text/html"
      "<dl>#{@data.map { |key, value| "<dt>#{HTML.escape(key)}</dt><dd>#{HTML.escape(value)}</dd>" }.join}</dl>"
    when "text/plain"
      @data.map { |key, value| "#{key}: #{value}" }.join("\n")
    else
      @data.to_json
    end
  end
end

struct NegotiatedEndpoint
  include Azu::Endpoint(Azu::Request, NegotiatedResponse)

  get "/negotiated"

  def call : NegotiatedResponse
    accept = header["Accept"]?.try(&.split(",").first) || "application/json"
    content_type accept
    NegotiatedResponse.new({"name" => "Ada"}, accept)
  end
end
```

## See also

- [Endpoint Reference](endpoint.md)
- [Request Reference](request.md)
- [Error Types Reference](../errors/error-types.md)

# Request Lifecycle

This document explains how HTTP requests flow through an Azu application from receipt to response.

## Overview

When a request arrives, it passes through several stages:

1. **Connection** - TCP connection established
2. **Parsing** - HTTP request parsed
3. **Handler Chain** - Middleware processing
4. **Routing** - Match to endpoint
5. **Request Binding** - Parse and validate input
6. **Execution** - Call endpoint logic
7. **Response** - Serialize and send output

## Stage 1: Connection

Crystal's HTTP server accepts the TCP connection:

```
Client ──TCP──→ Server
         ↓
    HTTP::Server accepts
         ↓
    Request object created
```

## Stage 2: Handler Chain

The request enters the handler pipeline:

```crystal
[Rescuer] → [Logger] → [Auth] → [Endpoint]
    ↓           ↓         ↓          ↓
 Wrap in    Log start  Check    Route &
 try/catch  time       token    execute
```

Each handler:
1. Receives the context
2. Optionally processes the request
3. Calls `call_next(context)`
4. Optionally processes the response

```crystal
class TimingHandler < Azu::Handler::Base
  def call(context)
    start = Time.monotonic
    call_next(context)        # ← Request goes down
    duration = Time.monotonic - start  # ← Response comes back
    context.response.headers["X-Response-Time"] = "#{duration}ms"
  end
end
```

## Stage 3: Routing

The router matches the path and method:

```
GET /users/123/posts

Router lookup:
  /users → :id → /posts → GET
           ↓
  Params: {"id" => "123"}
           ↓
  Handler: UserPostsEndpoint
```

The radix tree provides O(k) lookup where k is path length.

## Stage 4: Request Binding

The endpoint's request contract is populated:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
end
```

Binding process:
1. Detect content type (JSON, form, multipart)
2. Parse body according to type
3. Map parsed data to request properties
4. Run validations
5. Raise `ValidationError` if invalid

```
JSON Body: {"name": "Alice", "email": "a@b.com"}
                    ↓
CreateUserRequest(name: "Alice", email: "a@b.com")
                    ↓
           Validations pass
                    ↓
        Available in endpoint.call
```

## Stage 5: Endpoint Execution

The endpoint's `call` method runs:

```crystal
def call : UserResponse
  # Access validated request
  name = create_user_request.name

  # Business logic
  user = User.create!(name: name, email: email)

  # Return typed response
  UserResponse.new(user)
end
```

The call method has full access to:
- `params` - Route parameters
- `headers` - Request headers
- `context` - Full HTTP context
- Typed request object

## Stage 6: Response Serialization

The response object is rendered:

```crystal
struct UserResponse
  include Azu::Response

  def render
    {id: @user.id, name: @user.name}.to_json
  end
end
```

Response handling:
1. Call `render` method
2. Set Content-Type header
3. Write body to output
4. Set status code

## Stage 7: Handler Chain (Reverse)

The response travels back up the handler chain:

```
[Endpoint] → [Auth] → [Logger] → [Rescuer]
     ↓          ↓          ↓          ↓
  Response  Pass      Log end    Return
  created   through   time       to client
```

Each handler's code after `call_next` executes with the response available.

## Error Handling

When an exception occurs:

```
Exception raised in Endpoint
         ↓
Bubbles up through handlers
         ↓
Rescuer catches it
         ↓
Error response returned
```

The Rescuer handler converts exceptions to HTTP responses:

| Exception | Status | Behavior |
|-----------|--------|----------|
| `NotFound` | 404 | Resource not found |
| `ValidationError` | 422 | Validation details |
| Other | 500 | Internal error |

## WebSocket Lifecycle

WebSocket connections follow a different path:

```
HTTP Upgrade Request
        ↓
   Route to Channel
        ↓
   WebSocket Handshake
        ↓
┌───────────────────┐
│   on_connect      │ ← Connection established
├───────────────────┤
│   on_message      │ ← Each message
│   on_message      │
│   ...             │
├───────────────────┤
│   on_close        │ ← Connection closed
└───────────────────┘
```

## Performance Considerations

### Hot Path Optimization

The request hot path is optimized:
- Minimal allocations
- Cached route lookups
- Pre-compiled templates

### Context Pooling

HTTP contexts may be pooled for reuse, avoiding allocation overhead.

### Async I/O

Crystal's event loop handles I/O efficiently:
- Non-blocking sockets
- Fiber-based concurrency
- No thread pool overhead

## Timing Breakdown

Typical request timing:

| Stage | Time |
|-------|------|
| Parse | ~10μs |
| Route | ~200ns |
| Request binding | ~50μs |
| Database query | ~1-10ms |
| Response render | ~20μs |
| Total framework overhead | <1ms |

## See Also

- [Architecture Overview](overview.md)
- [Handler Reference](../../reference/handlers/built-in.md)
- [Router Reference](../../reference/api/router.md)

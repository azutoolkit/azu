# Request Lifecycle

This document follows an HTTP request through an Azu application, from the socket to the response. Every step
below was observed by running a real request through an in-process server; the program at the end prints the
order.

## Overview

1. **Connection** - Crystal's `HTTP::Server` accepts the connection and parses the request.
2. **App scope** - Azu marks the request as in flight and makes the app's configuration current.
3. **Handler chain** - your middleware, outermost first.
4. **Routing** - the router finds the endpoint for the method and path.
5. **Request contract** - the endpoint parses the request into its request type and validates it.
6. **Execution** - the endpoint's `call` runs.
7. **Response** - `render` is written to the connection.
8. **Handler chain, in reverse** - the code after each `call_next`.

## Stage 1: Connection

`HTTP::Server` from the standard library accepts the TCP connection, parses the request line, headers and a lazily
read body, and builds an `HTTP::Server::Context`. Azu does nothing here. Azu's `start` binds the listener (with TLS
when `config.tls?`) and installs the SIGINT and SIGTERM handlers described under
[graceful shutdown](../../reference/breaking-changes.md).

## Stage 2: App Scope

The first handler of every chain is `Azu::App::Scope`, added by `App#server`, not by you. It

- counts the request as in flight, so a stopping server can wait for it (`config.shutdown_timeout`),
- answers `503` with `Connection: close` and `Retry-After: 1` once the app is shutting down,
- makes the app's `Configuration` current for this fiber, which is what `Azu.current_config` and `Azu.cache` read.

## Stage 3: Handler Chain

The handlers you passed to `start` (or `Azu::App#default_handlers`: `RequestId`, `Logger`, `Rescuer`,
`SecurityHeaders`, `Static`) run in array order. Each one

1. receives the context,
2. optionally acts on the request,
3. calls `call_next(context)`, or answers itself and returns,
4. optionally acts on the response.

```crystal
class TimingHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    start = Time.instant
    call_next(context)                         # the request goes down
    elapsed = Time.instant - start             # the response comes back
    context.response.headers["X-Elapsed"] = elapsed.total_milliseconds.round(2).to_s
  end
end
```

A handler that does not call `call_next` ends the request; handlers after it, the router and the endpoint never
run. `Static` with `fallthrough: true` calls `call_next` only for paths that match no file.

## Stage 4: Routing

After the last handler the app's router takes the request. `Router#process`

1. applies the method override: a `POST` may ask to be handled as `PUT`, `PATCH` or `DELETE` with an
   `X-HTTP-Method-Override` header, a `_method` query parameter or a `_method` field of a urlencoded form (a `POST`
   with `X-HTTP-Method-Override: DELETE` reached the `DELETE` endpoint; an override to `GET` is ignored),
2. looks the method and path up in a radix tree (the `radix` shard); WebSocket upgrades are looked up under a `/ws` prefix,
3. answers an unmatched request itself with a `404` error response in the format of the `Accept` header, without
   raising, and logs the miss from the `Router` source,
4. stores the matched parameters (`/users/:id`) in `context.request.path_params` and the endpoint name in the
   `X-Azu-Endpoint` request header (which `Logger` prints), and
5. calls the endpoint.

Routes come from the endpoint macros (`get "/users/:id"` in the endpoint body, registered on `Azu::App.default`) or
from `app.routes { get "/users/:id", UserEndpoint }`, which also offers `scope` and `mount`.

## Stage 5: The Request Contract

Inside the endpoint, before `call`, Azu builds the request object from the JSON body or, otherwise, from the
form-encoded body and query string, and validates it. For a contract with no fields and no rules there is nothing to
check: a request without a `Content-Type` skips this step, and its params are read on first use.

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  validate name, presence: true
  validate email, presence: true
end
```

- A body that cannot become the request type (malformed JSON, `"abc"` for an `Int32`, in JSON or in a form) raises
  `Azu::Response::BadRequest`: `400`.
- A request that breaks a validation raises `Azu::Response::ValidationError`: `422` with an
  `application/problem+json` body listing the failing fields.
- Otherwise the parsed request is available in `call` as `create_user_request`, parsed once per call.

Both errors are raised before `call`, so an endpoint never sees an invalid request. They are answered by `Rescuer`.
An endpoint declared with the bare `Azu::Request` module has no contract and skips this stage.

## Stage 6: Endpoint Execution

`call` runs with `params` (path parameters, query string and form body), `context` (the whole
`HTTP::Server::Context`) and the typed request. It returns an `Azu::Response`:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  validate name, presence: true
end

struct CreateUserResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    {name: @name}.to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, CreateUserResponse)

  post "/users"

  def call : CreateUserResponse
    content_type "application/json"
    CreateUserResponse.new(create_user_request.name)
  end
end
```

While `call` runs, `Azu::RequestContext.current?` gives the request id, method, path and endpoint name for anything
that logs or measures work on behalf of the request.

## Stage 7: Response

The endpoint writes what `render` returns to `context.response`. Set the content type in `call` with
`content_type`, the status with `status` and headers with `header`. A small body stays buffered until the
endpoint returns. A large one (100 000 bytes in a test) starts leaving as it is written, after which the head
(status and headers) can no longer change, so a handler's header set after `call_next` is lost.

## Stage 8: Handler Chain, in Reverse

The response travels back out through the handlers: the code after each `call_next` runs, innermost first.

An exception does not unwind politely. It skips the code after `call_next` of every handler between the raise and
the `Rescuer` that catches it, so a handler that must always run its second half (a timer, a resource) uses
`ensure`. `Logger` does, which is why it logs requests that raised.

## Error Handling

```text
exception raised in the endpoint (or a handler, or the contract)
        ↓
bubbles up through the handlers after Rescuer, skipping their code after call_next
        ↓
Rescuer catches it and writes the error response
        ↓
the handlers before Rescuer (Logger, RequestId) see a normal return with the error status
```

| Raised | Status |
|---|---|
| `Response::NotFound` | 404 |
| `Response::BadRequest` | 400 |
| `Response::AuthenticationError` | 401 |
| `Response::Forbidden` | 403 |
| `Response::ValidationError` | 422 |
| any other `Response::Error` | its own status |
| any other exception | 500 |

The full table is in the [handler reference](../../reference/handlers/built-in.md#handlerrescuer). A handler placed
before `Rescuer` is not protected by it.

## Watching the Lifecycle

This program serves one endpoint behind two tracing handlers with `Rescuer` between them and sends three
requests: a valid one, one that breaks the contract and one with a body that is not JSON.

```crystal
require "azu"
require "http/client"

STEPS = [] of String

class Step
  include HTTP::Handler

  def initialize(@name : String)
  end

  def call(context : HTTP::Server::Context)
    STEPS << "#{@name} in"
    call_next(context)
    STEPS << "#{@name} out (#{context.response.status_code})"
  end
end

struct GreetRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  validate name, presence: true
end

struct GreetResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    STEPS << "render"
    %({"hello":"#{@name}"})
  end
end

struct GreetEndpoint
  include Azu::Endpoint(GreetRequest, GreetResponse)

  post "/greet"

  def call : GreetResponse
    STEPS << "endpoint call"
    GreetResponse.new(greet_request.name)
  end
end

handlers = [Step.new("A"), Azu::Handler::Rescuer.new, Step.new("B")] of HTTP::Handler
server = Azu::App.default.server(handlers)
address = server.bind_unused_port("127.0.0.1")
spawn { server.listen }
Fiber.yield

client = HTTP::Client.new(address.address, address.port)
headers = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}

[%({"name": "Ada"}), %({"name": ""}), "not json"].each do |body|
  STEPS.clear
  response = client.post("/greet", headers, body)
  puts "#{response.status_code} #{response.body[0, 40]}"
  puts STEPS.join(" > ")
end
server.close
```

Its output (the log lines `Rescuer` writes for the two errors are left out):

```text
200 {"hello":"Ada"}
A in > B in > endpoint call > render > B out (200) > A out (200)
422 {"type":"about:blank","title":"Validatio
A in > B in > A out (422)
400 {"type":"about:blank","title":"Bad Reque
A in > B in > A out (400)
```

In the failing requests `B out` is missing: the exception skipped it on its way to `Rescuer`, while `A`, outside
`Rescuer`, saw the `422` and the `400`.

## WebSocket Lifecycle

A WebSocket channel is routed like an endpoint (`ws "/chat"`); the upgrade request goes through the same handler
chain and router, and the router hands it to the channel's upgrader. The channel's callbacks then run:

```text
on_connect   when the socket is open
on_message   for each text message
on_binary    for each binary message
on_ping, on_pong
on_close     when the connection ends
```

See the [channel reference](../../reference/api/channel.md).

## What Costs Time

Where the time of a request goes is measured, not estimated, in
[Performance Design](performance-design.md#measured).

## See Also

- [Architecture Overview](overview.md)
- [Handler Reference](../../reference/handlers/built-in.md)
- [Router Reference](../../reference/api/router.md)

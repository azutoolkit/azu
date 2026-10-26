# Create custom middleware

Write your own handlers. A handler is any class that includes `HTTP::Handler` and
implements `call(context)`; Azu has no base class of its own. Before writing one, check
[the built-in handlers](../../reference/handlers/built-in.md): request ids, logging, error pages, security
headers, static files, CORS, CSRF, rate limiting, compression and health checks already exist.

## Basic Handler

```crystal
class TimingHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    start = Time.instant

    call_next(context)

    elapsed = Time.instant - start
    context.response.headers["X-Response-Time"] = "#{elapsed.total_milliseconds.round(2)}ms"
  end
end
```

`call_next(context)` runs the rest of the chain and the endpoint. Code before it sees the request, code after it
sees the response.

A header set after `call_next` is lost once the response has started to leave the server, which happens for a large
body, a `flush` or a stream. Anything you can decide before
the endpoint runs belongs before `call_next`; `X-Response-Time` is best effort.

## Register the Handler

Pass the handlers to `start`, outermost first. The router (and with it every endpoint) always comes last, so
endpoints are not listed:

```crystal
module MyApp
  include Azu
end

class TimingHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    call_next(context)
  end
end

MyApp.start [
  Azu::Handler::RequestId.new,
  TimingHandler.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
] of HTTP::Handler
```

An array you pass replaces the default stack (`RequestId`, `Logger`, `Rescuer`, `SecurityHeaders`, `Static`), so list
the ones you still want. To extend the default stack instead, build on it:

```crystal
module MyApp
  include Azu
end

class TimingHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    call_next(context)
  end
end

handlers = Azu::App.default.default_handlers
handlers.insert(1, TimingHandler.new)
MyApp.start handlers
```

`default_handlers` returns new instances each call, because a handler instance can be in one chain only.

## Authentication Handler

Answer failures by raising an `Azu::Response::Error`: `Rescuer` (keep it **before** this handler in the array)
renders it as JSON, HTML or text according to the request's `Accept` header, with the right status code:

```crystal
class TokenAuthHandler
  include HTTP::Handler

  PUBLIC_PATHS = ["/", "/login", "/health"]

  def initialize(@tokens : Hash(String, Int64))
  end

  def call(context : HTTP::Server::Context)
    # Never trust a header the client may have sent itself.
    context.request.headers.delete("X-User-ID")
    return call_next(context) if PUBLIC_PATHS.includes?(context.request.path)

    user_id = bearer_token(context).try { |token| @tokens[token]? }
    raise Azu::Response::AuthenticationError.new unless user_id

    context.request.headers["X-User-ID"] = user_id.to_s
    call_next(context)
  end

  private def bearer_token(context : HTTP::Server::Context) : String?
    context.request.headers["Authorization"]?.try do |header|
      header.lchop?("Bearer ")
    end
  end
end
```

In an array: `[RequestId.new, Rescuer.new, TokenAuthHandler.new({"s3cret" => 42_i64})]`. A request without the token
gets `401`; with `Authorization: Bearer s3cret` the endpoint sees `X-User-ID: 42`, and a forged `X-User-ID: 1` sent
without a token gets `401` too. An endpoint reads the value with
`context.request.headers["X-User-ID"]?`.

To answer without `Rescuer`, or with your own body, write the response yourself and return without
calling `call_next`:

```crystal
class ApiKeyHandler
  include HTTP::Handler

  def initialize(@key : String)
  end

  def call(context : HTTP::Server::Context)
    unless context.request.headers["X-Api-Key"]? == @key
      context.response.status_code = 401
      context.response.content_type = "application/json"
      context.response.print({error: "Unauthorized"}.to_json)
      return
    end

    call_next(context)
  end
end
```

## Use the Built-in Handler First

These are commonly written by hand and exist already:

| You want | Use |
|---|---|
| Allow another origin to call the API | `Azu::Handler::CORS.new(origins: [...] of (String \| Regex))`, which also answers preflight requests |
| Limit requests per client | `Azu::Handler::Throttle.new(interval: 5, duration: 900, threshold: 100, blacklist: [] of String, whitelist: [] of String)` |
| A request id on every request and response | `Azu::Handler::RequestId.new` |
| Gzip or deflate responses | `Azu::Handler::Compression.new`, after `Static` |
| Security headers | `Azu::Handler::SecurityHeaders.new` |
| A `/health` probe | `Azu::Handler::HealthCheck.new` |

Compressing in your own handler after `call_next` does not work: `context.response.output` is the connection, not a
buffer holding the body. `Compression` wraps the output before the rest of the chain runs.

## A Handler with a Block

A handler that decides per request can take a block:

```crystal
class ConditionalHandler
  include HTTP::Handler

  def initialize(&@condition : HTTP::Server::Context -> Bool)
  end

  def call(context : HTTP::Server::Context)
    if @condition.call(context)
      context.response.headers["X-Api-Version"] = "1"
    end

    call_next(context)
  end
end

ConditionalHandler.new { |context| context.request.path.starts_with?("/api") }
```

## Wrapping Other Handlers

Because a handler is just an object, one handler can run another only for some requests. The wrapped handler
must be given the rest of the chain:

```crystal
class OnlyFor
  include HTTP::Handler

  def initialize(@prefix : String, @handler : HTTP::Handler)
  end

  def call(context : HTTP::Server::Context)
    if context.request.path.starts_with?(@prefix)
      @handler.next = self.next
      @handler.call(context)
    else
      call_next(context)
    end
  end
end

OnlyFor.new("/api", Azu::Handler::Throttle.new(interval: 5, duration: 60, threshold: 20, blacklist: [] of String, whitelist: [] of String))
```

## Handler Ordering

Order matters (see [the middleware concept](../../explanation/concepts/middleware.md#ordering-best-practices)):

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,                        # ids first: logs and errors carry them
  Azu::Handler::Logger.new,                           # outside Rescuer: logs the final status
  Azu::Handler::Rescuer.new,                          # errors raised below become responses
  Azu::Handler::SecurityHeaders.new,
  Azu::Handler::CORS.new(origins: ["https://app.example.com"] of (String | Regex)), # before authentication
  Azu::Handler::Static.new(fallthrough: true),        # public files need no authentication
  Azu::Handler::Throttle.new(interval: 5, duration: 900, threshold: 100, blacklist: [] of String, whitelist: [] of String),
] of HTTP::Handler
```

## Testing a Handler

Serve it on a free port and send real requests through it:

```crystal
require "spec"
require "azu"
require "http/client"

class StampHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    context.response.headers["X-Stamp"] = "yes"
    call_next(context)
  end
end

struct PingResponse
  include Azu::Response

  def render
    "pong"
  end
end

struct PingEndpoint
  include Azu::Endpoint(Azu::Request, PingResponse)

  get "/ping"

  def call : PingResponse
    PingResponse.new
  end
end

def serve(handlers : Array(HTTP::Handler), &)
  server = Azu::App.default.server(handlers)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield HTTP::Client.new(address.address, address.port)
  ensure
    server.close
  end
end

describe StampHandler do
  it "adds its header and lets the endpoint answer" do
    serve([StampHandler.new] of HTTP::Handler) do |client|
      response = client.get("/ping")

      response.status_code.should eq 200
      response.body.should eq "pong"
      response.headers["X-Stamp"].should eq "yes"
    end
  end
end
```

## See Also

- [Add Logging](add-logging.md)
- [Built-in handlers](../../reference/handlers/built-in.md)

# Optimize endpoints

Make Azu endpoints faster. For what the framework itself costs and how to measure it, see
[Performance Design](../../explanation/architecture/performance-design.md).

## Declare Endpoints as Structs

The router keeps one endpoint value per route, and each request works on its own copy: a `struct` is copied on
dispatch, and a `class` is `dup`ed before `call`. So the params and context `call` sees are its own either way, even
while `call` waits (a query, a `sleep`) and other requests to the same route run. A `struct` copy needs no extra heap
object, which the `dup` of a class does. Both copies are shallow: an object that an instance variable points to is
shared by every request, so keep request state in local variables.

```crystal
require "azu"

struct EchoResponse
  include Azu::Response

  def initialize(@id : String)
  end

  def render
    @id
  end
end

struct EchoEndpoint
  include Azu::Endpoint(Azu::Request, EchoResponse)

  get "/echo/:id"

  def call : EchoResponse
    EchoResponse.new(params["id"])
  end
end
```

## Cache Computed Responses

`Azu.cache.fetch` runs the block on a miss and stores the result; many simultaneous misses of one key compute it
once. Cache the rendered body:

```crystal
require "azu"

struct CatalogPage
  include Azu::Response

  def initialize(@json : String)
  end

  def render
    @json
  end
end

struct CatalogEndpoint
  include Azu::Endpoint(Azu::Request, CatalogPage)

  get "/catalog"

  def call : CatalogPage
    content_type "application/json"
    page = params["page"]? || "1"

    json = Azu.cache.fetch("catalog:page:#{page}", 5.minutes) do
      {page: page, items: (1..3).map { |i| "item #{i}" }}.to_json
    end

    CatalogPage.new(json)
  end
end
```

Include everything that changes the answer in the key (page, locale, filters), and invalidate with
`Azu.cache.delete` where the data is written. The cache is in memory by default; see
[Set Up Memory Cache](../caching/setup-memory-cache.md).

## HTTP Caching Headers

Let clients and proxies reuse responses: send `Cache-Control` and an `ETag`, and answer `304 Not Modified`, without a
body, when the client already has the current version:

```crystal
require "azu"

struct ArticleResponse
  include Azu::Response

  def initialize(@body : String)
  end

  def render
    @body
  end
end

struct ArticleEndpoint
  include Azu::Endpoint(Azu::Request, ArticleResponse)

  get "/articles/:id"

  def call : ArticleResponse
    revision = 7
    etag = %("article-#{params["id"]}-#{revision}")

    header "Cache-Control", "public, max-age=60"
    header "ETag", etag

    if context.request.headers["If-None-Match"]? == etag
      status 304
      return ArticleResponse.new("")
    end

    ArticleResponse.new("Article #{params["id"]}, revision #{revision}")
  end
end
```

A repeated request with `If-None-Match` set to the `ETag` gets `304` with an empty body. For files in
`public/`, `Azu::Handler::Static` already does this (weak `ETag`, `Cache-Control: public, no-cache` and, for names
with a content hash such as `app-3f2a9c1b.css`, `max-age=31536000, immutable`).

## Compress Responses

Put `Azu::Handler::Compression` after `Static` in the handler array. It gzips or deflates responses for clients that
send `Accept-Encoding`:

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::SecurityHeaders.new,
  Azu::Handler::Static.new(fallthrough: true),
  Azu::Handler::Compression.new,
] of HTTP::Handler
```

Do not write a handler that compresses by reading `context.response.output` after `call_next`; that is not where the body is.

## Stream Large Responses

An endpoint can write to `context.response` itself and flush as it goes; with no `Content-Length` the server sends the
body chunked. Return `Azu::Response::Empty` so nothing more is written:

```crystal
require "azu"

struct ExportEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/export"

  def call : Azu::Response::Empty
    response = context.response
    response.content_type = "application/json"

    response.print "["
    5.times do |i|
      response.print "," if i > 0
      response.print({id: i}.to_json)
      response.flush
    end
    response.print "]"

    Azu::Response::Empty.new
  end
end
```

Once the first chunk is flushed the status and headers are fixed. A streamed response is also a request that stays in
flight until it finishes, which `shutdown_timeout` waits for. End the loop when `Azu.shutting_down?` turns true (or
wait on `Azu.shutdown_signal`) so a stop does not wait for it; see
[Shut Down Gracefully](../deployment/graceful-shutdown.md).

## Do Not Block Requests on Slow Side Work

Work the client does not wait for (analytics, emails) can run after you answer. Start it in a fiber that rescues its
own errors, and use `Azu.spawn_scoped` so the fiber keeps this app's configuration:

```crystal
require "azu"

struct SignupAck
  include Azu::Response

  def render
    "welcome"
  end
end

struct TrackedSignupEndpoint
  include Azu::Endpoint(Azu::Request, SignupAck)

  post "/track-signup"

  def call : SignupAck
    path = context.request.path

    Azu.spawn_scoped do
      Log.for("analytics").info { "signup tracked from #{path}" }
    rescue ex
      Log.for("analytics").error(exception: ex) { "tracking failed" }
    end

    SignupAck.new
  end
end
```

For work that must not be lost when the process stops, use a job queue; a fiber dies with the process.

## Time Limits

Crystal has no request timeout setting in Azu. Bound a slow call with `select` and `timeout`, and raise
`Azu::Response::TimeoutError` so `Rescuer` answers `408`:

```crystal
require "azu"

struct SlowResponse
  include Azu::Response

  def initialize(@value : String)
  end

  def render
    @value
  end
end

struct SlowEndpoint
  include Azu::Endpoint(Azu::Request, SlowResponse)

  get "/slow"

  def call : SlowResponse
    # One slot of buffer: the fiber can deliver its result and finish even after the timeout
    result = Channel(String).new(1)

    spawn do
      sleep 2.seconds # stands in for a slow upstream
      result.send("late")
    end

    select
    when value = result.receive
      SlowResponse.new(value)
    when timeout(200.milliseconds)
      raise Azu::Response::TimeoutError.new
    end
  end
end
```

The spawned fiber keeps running after the timeout; with the buffer, its `send` does not wait for a receiver, so the
fiber ends when the slow call does.

## Measure

Do not guess where time goes. With `require "azu/dev"`, `Azu::Handler::PerformanceMonitor` records the time of every
request and `Azu::Instrumentation.on_cache` every cache operation; see
[Performance Design](../../explanation/architecture/performance-design.md#measuring-your-application).

## See Also

- [Performance Design](../../explanation/architecture/performance-design.md)
- [Optimize Database Queries](optimize-database-queries.md)
- [Set Up Memory Cache](../caching/setup-memory-cache.md)

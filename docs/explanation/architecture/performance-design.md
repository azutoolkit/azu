# Performance design

This document describes what Azu does to keep requests cheap, what it does not do, and how to measure your own
application. It contains only properties that were read in the source or measured, and says how each number was
obtained.

## What Azu Builds On

Azu is compiled by Crystal to native code. Method calls on concrete types are resolved at compile time, and generics
(`Endpoint(Request, Response)`) are specialized per type, so there is no reflection on the request path. The HTTP
server, the connection handling (a fiber per connection) and the non-blocking I/O are Crystal's standard library;
Azu adds the handlers, router and endpoint layer on top.

## Router

Routes live in a radix tree (the `radix` shard), keyed by method and path. A lookup walks the tree by path segment.

### The Path Cache

Before the lookup the router builds the string it searches for (`"/get/users/42"`, or `"/ws/chat"` for an
upgrade). That string is cached per `method:path` in a hash guarded by a mutex:

```text
GET /users/42  →  cache key "GET:/users/42"  →  lookup string "/get/users/42"
```

The cache holds the **lookup string**, not the matched route, and it is bounded at 1000 entries with **no
eviction**: once it is full, new paths are simply not added. A site with more than 1000 distinct URLs (an id per
page) stops adding entries after the thousandth and builds the string for the rest on each request. Routes with
parameters are therefore cached per distinct path, not per route.

## Request Processing

- **The request is parsed once per call**, before `call`, because the contract is enforced before the endpoint
  runs. Parsing is not lazy: an endpoint with a request type pays for parsing and validation, even when `call`
  never reads the request. Two exceptions read params on first use: an endpoint declared with the bare
  `Azu::Request` module, which has no contract, and a contract with no fields, no rules and no methods of its
  own, for a request without a `Content-Type`.
- **Endpoints are copied per call.** The router holds one endpoint value per route; a `struct` endpoint is copied for
  every request, so the instance variables `call` sets (the context, the params) belong to that request. A `class`
  endpoint is one object shared by all concurrent requests, and its params and context are overwritten by the next
  request that arrives while the first one waits. Three simultaneous requests to a class endpoint that slept in
  `call` all saw the params of the last one. Declare endpoints as `struct`s.
- **Handlers are created once.** The handler array is built at startup and every request goes through the same
  instances, so handler state is shared by all requests (use `Atomic` or `Mutex`).

## Response Generation

An endpoint returns an object whose `render` produces the body; it is written to the connection by `<<`. Small
bodies are buffered by the standard library and written when the endpoint returns, large ones leave while they are
written. `Static` sends files with a weak `ETag` derived from the file's modification time, answers `304` to a matching
`If-None-Match`, serves byte ranges, and gzips or deflates compressible types larger than 860 bytes when the client
accepts it. `Compression` gives other responses the
standard library's gzip.

## Templates

With `template_hot_reload` off (every environment but development, test and pipeline), `Azu::Templates` compiles:
`Azu.prepare` reads and parses every template file once and keeps the result in an immutable map, so a render does
a lookup by name and no file is read or parsed per request. All templates stay resident in memory, an edited file
needs a restart (also a template mounted into a container from a volume or a Kubernetes ConfigMap), and a template
that does not parse stops the boot. With reload on, Crinja asks the file loader on each render and a check (at most
once a second) rebuilds the loader. The rendering itself, the largest part of a request, still happens in Crinja on
every request; if it is a hot spot, cache the rendered fragment:

```crystal
require "azu"

def sidebar_html(user_id : Int64) : String
  Azu.cache.fetch("sidebar:#{user_id}", 5.minutes) do
    "<aside>rendered once per user and five minutes</aside>"
  end
end
```

## Caching

`Azu.cache` is a memory store with LRU eviction by default (or Redis); `fetch` computes a missing value once even
when many fibers ask for it at the same time. See [the cache reference](../../reference/api/cache.md). Neither components nor
HTTP contexts are pooled; there is no pooling code in the framework.

## Concurrency

Every connection runs in a fiber, scheduled cooperatively by Crystal. A fiber yields on I/O (sockets, `sleep`, channel
operations), so a request waiting on a socket does not block the others, and CPU-bound work in an endpoint does
block the thread it runs on. Move heavy computation to a background job, or `spawn` it and answer
earlier. The upload, cache cleanup and heartbeat tasks are fibers of the same process.

## Measured

Numbers below come from `crystal run --release` (Crystal 1.22.0) on a 4-core virtual machine that was running other
containers at the same time, so treat them as an order of magnitude, not as a benchmark of Azu on dedicated
hardware. The program is this one; it was run three times (the first time as an earlier copy of the same loops):

```crystal
require "azu"
require "http/client"

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

struct UserPostEndpoint
  include Azu::Endpoint(Azu::Request, PingResponse)

  get "/users/:id/posts/:post_id"

  def call : PingResponse
    PingResponse.new
  end
end

def context_for(path : String) : HTTP::Server::Context
  HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(IO::Memory.new))
end

# 1. The router and the endpoint, without a socket.
router = Azu::App.default.router
runs = 200_000
["/ping", "/users/42/posts/7"].each do |path|
  1_000.times { router.process(context_for(path)) }
  started = Time.instant
  runs.times do
    context = context_for(path)
    router.process(context)
    context.response.close
  end
  puts "router.process #{path}: #{((Time.instant - started).total_microseconds / runs).round(2)} µs per request"
end

# 2. The default handler stack (without the request log) over a loopback socket, one keep-alive client.
app = Azu::App.default
server = app.server(app.default_handlers.reject(&.is_a?(Azu::Handler::Logger)))
address = server.bind_unused_port("127.0.0.1")
spawn { server.listen }
Fiber.yield
client = HTTP::Client.new(address.address, address.port)
1_000.times { client.get("/ping") }
requests = 20_000
started = Time.instant
requests.times { client.get("/ping") }
elapsed = Time.instant - started
puts "loopback GET /ping: #{(elapsed.total_microseconds / requests).round(1)} µs per request (#{(requests / elapsed.total_seconds).round} requests/s)"
server.close
```

| Measurement | Range over three runs |
|---|---|
| `router.process` for `/ping`, including building the context and writing the response into memory | 7.5 to 13.2 µs per request |
| `router.process` for `/users/42/posts/7` (two parameters) | 9.2 to 13.0 µs per request |
| One keep-alive client, loopback socket, default handlers without `Logger`, request and response parsing by the standard library included | 21.7 to 25.2 µs per request (about 40 000 to 46 000 requests per second) |

The loopback figure is one sequential client: it measures latency per request, not the throughput of a loaded
server, and it includes the client's own work. Requests that parse a body, render a template or query a database
cost what that work costs; measure those in your own application.

## Measuring Your Application

With `require "azu/dev"`, `Azu::Handler::PerformanceMonitor` records every request that passes through it
(endpoint, status, processing time, memory) and `metrics.aggregate_stats` summarizes them:

```crystal
require "azu"
require "azu/dev"
require "http/client"

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

monitor = Azu::Handler::PerformanceMonitor.new
server = Azu::App.default.server([Azu::Handler::RequestId.new, monitor] of HTTP::Handler)
address = server.bind_unused_port("127.0.0.1")
spawn { server.listen }
Fiber.yield

client = HTTP::Client.new(address.address, address.port)
50.times { client.get("/ping") }
server.close

stats = monitor.metrics.aggregate_stats
puts "requests: #{stats.total_requests}"
puts "errors:   #{stats.error_requests}"
puts "average:  #{stats.avg_response_time.round(3)} ms"
puts "p95:      #{stats.p95_response_time.round(3)} ms"
```

In an application put the monitor in the handler array of `start`; `Azu::Handler::DevDashboard` shows the same data
in the browser during development (and only then: it passes every request on in any other environment). Cache operations are observable with `Azu::Instrumentation.on_cache` (see the
[cache reference](../../reference/api/cache.md#observing-the-cache)), and the database tab of the dashboard lists
slow queries and N+1 patterns (see [Database dashboard](../../reference/database-dashboard.md)).

Without `require "azu/dev"` none of this is loaded: core calls `Azu::Instrumentation`, which costs a nil check until
something subscribes.

## Profiling

Build with `--release` before measuring anything, and use the profiler of your platform on the binary:

```bash
crystal build --release src/app.cr -o app
perf record -g ./app
perf report
```

## Practical Rules

1. **Declare endpoints as `struct`s** (see above).
2. **Paginate and limit** what an endpoint reads; the work of an endpoint is usually its database access, which the
   dashboard's database tab shows per request.
3. **Cache rendered or computed values** with `Azu.cache.fetch`, and give every entry a TTL.
4. **Build strings with `String.build`** instead of `+=` in loops.
5. **Keep CPU-bound work out of request fibers.**

## See Also

- [Architecture Overview](overview.md)
- [How to Optimize Endpoints](../../how-to/performance/optimize-endpoints.md)
- [How to Optimize Database Queries](../../how-to/performance/optimize-database-queries.md)

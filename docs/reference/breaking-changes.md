# Breaking Changes

This document lists breaking changes between Azu versions and migration guides.

## Version 0.5.x

### Unreleased (0.6 work)

Step by step, with old and new code side by side: [Migrate to 0.6](../how-to/migrate-to-0.6.md).

**The global shim is deprecated.** `include Azu`, `configure` and `start` still work, and log one warning per
process (at the first call, not when requiring azu) that names `Azu::App`.

**Per-app leftovers.** Building a configuration no longer applies its `i18n` settings to the process-wide
`Helpers::I18n` (`I18nConfiguration#apply` does, called when an app builds its server). `Handler::Logger`,
`SimpleLogger` and `Throttle` log to the app serving the request unless given `log:`, and resolve it on every call.

**Requiring `azu` no longer starts anything.** Before, `require "azu"` set the root `Log` level to `Debug`
with Azu's formatter, created the upload temp directory and started seven background fibers.

- Logging: neither `require "azu"` nor `start` configures `Log` any more, so an app that sets up `Log`
  itself keeps its backend and level. To get the previous Azu format at `Debug`, call
  `Azu.setup_logging` once at boot (before `start`).
- The async log pipeline starts on the first log entry or reported error, or in `start`.
- The upload temp directory and its cleanup task are created by `start` (or by the first upload for
  apps that never call `start`).
- The profiler and memory monitor (`azu/dev`) that development mode turns on by default now start in `start`
  instead of when the configuration is built.

**The dev dashboard and performance tooling are opt-in: `require "azu/dev"`.** `require "azu"` no longer
loads them, and core no longer has the ~25 `PERFORMANCE_MONITORING` compile-time blocks. Core only calls
`Azu::Instrumentation`, which costs a nil check until `azu/dev` subscribes.

These now exist only after `require "azu/dev"` (the fix for each is the same: add that line after
`require "azu"`):

- `Azu::Handler::DevDashboard`, `Azu::Components::DevDashboardComponent` and the `Dashboard` sections
- `Azu::Handler::PerformanceMonitor`, `Azu::PerformanceMetrics`
- `Azu::PerformanceReporter`, `LogPerformanceReporter`, `JsonPerformanceReporter`,
  `PerformanceMonitoringManager`, `PerformanceReportScheduler`, `PerformanceReportService`
- `Azu::DevelopmentTools` (profiler, memory leak detector, benchmark)
- `Configuration#performance_enabled?`, `#performance_profiling_enabled?`, `#performance_memory_monitoring?`
  (and their setters), `#performance_monitor` and `#performance_monitor=`, `#development_tools`.
  `performance_profiling_enabled?` and `performance_memory_monitoring?` now follow `config.env` while
  their environment variable is unset, instead of reading the environment once when the
  configuration was built.

Other changes:

- `Azu::Cache::Manager#metrics` / `#metrics=` and the second `Manager.new` argument are gone, and so is
  `PerformanceMetrics.time_cache_operation`. With `azu/dev` loaded, cache operations are recorded in the
  current configuration's monitor whenever `performance_enabled?` is on; no per-manager wiring.
- Component and cache metrics no longer need the `PERFORMANCE_MONITORING` build flag: `azu/dev` plus
  `performance_enabled?` is enough.
- Cache and component metrics belong to the configuration of the fiber that runs the operation
  (`Azu.current_config`), not to the manager's. Start background fibers with `Azu.spawn_scoped` so they
  report to the app they serve.
- `Azu::Instrumentation` is the hook point for your own tooling: `on_cache { |operation| }`,
  `on_component { |event| }` (several subscribers can coexist; each takes an optional `enabled` predicate
  that keeps timing off while it answers false), and `on_prepare` / `on_finalize` for `Azu.start` and
  configuration teardown. A subscriber or hook that raises is logged at debug level and ignored.
- Building with `PERFORMANCE_MONITORING=true` or `-Dperformance_monitoring` still works unchanged: it makes
  `require "azu"` also load `azu/dev`.
- Files moved: `src/azu/{performance_metrics,performance_reporter,development_tools}.cr`,
  `src/azu/handler/{dev_dashboard,performance_monitor}.cr` and `src/azu/components/dev_dashboard*` are under
  `src/azu/dev/`. Require `azu/dev`, not the files.

**Template helpers no longer read `_session` and `_flash` cookies.** `Helpers::TemplateContext#session` and
`#flash` decoded an unsigned Base64 JSON cookie that no session library writes, so any client could forge
its session or flash. They now read through `Azu.session_adapter` (`Azu::SessionAdapter`, additive and opt-in,
stored on `Configuration#session_adapter`, no dependency on a session shard) and are empty without one. With the `session` shard (`require "session/azu"`)
install an adapter once at boot; see `docs/how-to/middleware/use-sessions.md`. Apps that wrote those cookies
themselves must move to a session store.

**CSRF token stores** (additive). `Handler::CSRF.new(token_store:)` chooses where the `SynchronizerToken` strategy
keeps its token: `CookieTokenStore` (default, unchanged) or `SessionTokenStore`, which uses
`Azu.session_adapter` so the token never reaches the client as a cookie.

**Routes can belong to an app** (additive; the endpoint macros keep registering on `Azu::App.default`). The
macros now record their routes on the endpoint type (`.routes`) and `App.default` registers them lazily, the first
time its router is read, instead of when the class body runs; `Router::Builder#endpoint(Type)` registers a type on any
other app. Observable differences: a duplicate route raises when the router is first used (`App#server` and
`Azu.start` do it at boot) rather than at class definition, and code that reads `Azu::CONFIG.router` still sees every
declared route because the router getter applies them.

```crystal
require "azu"

struct TextResponse
  include Azu::Response

  def initialize(@text : String)
  end

  def render
    @text
  end
end

struct UserEndpoint
  include Azu::Endpoint(Azu::Request, TextResponse)

  def call : TextResponse
    TextResponse.new("user")
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(Azu::Request, TextResponse)

  def call : TextResponse
    TextResponse.new("created")
  end
end

admin_app = Azu::App.new

app = Azu::App.new
app.routes do
  get "/users/:id", UserEndpoint
  scope "/api" do
    post "/users", CreateUserEndpoint
  end
  mount admin_app, at: "/admin"
end
```

- `scope` really prefixes now (`Router::Builder` used to ignore its scope).
- `mount` serves another app below a prefix with that app's own router and configuration. An app can be
  mounted once; build one app per mount.
- `Endpoint.path` includes the prefix the app is mounted at and the scope the route was declared in,
  so links stay right wherever the endpoint is mounted. A link to an endpoint another app routes is
  returned without any prefix.
- `Router#routes { }` now yields `Router::Builder`, which declares verbs, `ws`, `scope` and `mount`; it no
  longer forwards other calls (`root`, `add`) to the router.

**Request contracts are enforced.** An endpoint whose request type has validations no longer runs when the
request breaks them: the endpoint answers `422` before `call` (by itself, whether or not a `Rescuer` is in the handler stack),
and the parsed request is built once per call.

- The body is RFC 7807 `application/problem+json`:
  `{"type": "about:blank", "title": "Validation Error", "status": 422, "detail": "...", "errors": {"name": ["must be present"]}}`.
- To keep the pre-0.6 body (`FieldErrors`, `ErrorId`, ...) for one more minor release, set
  `config.error_format = Azu::ErrorFormat::Legacy`.
- The request is parsed before `call` even when the endpoint never reads it, so a body that cannot be parsed
  into the request type (for example a missing non-nilable field on a GET) answers `400` before `call`, also
  without a `Rescuer`.
  Endpoints that validate by hand (`if signup_request.valid?` then re-render a form) no longer get to run
  for invalid input; declare such an endpoint with a request type without validations.
- Endpoints declared with the bare `Azu::Request` module have no contract and are not affected.

**A default handler stack** (additive). `MyApp.start` without arguments serves
`RequestId, Logger, Rescuer, SecurityHeaders, Static` (`Azu::App#default_handlers`). Passing an array
keeps today's behaviour exactly: it is used as given and nothing is added to it.

- `Handler::SecurityHeaders`: `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`; HSTS and a
  `Content-Security-Policy` only when asked for (`hsts: true`, `content_security_policy: "..."`). Headers
  the application already set are left alone.
- `Handler::Compression`: gzip/deflate, the standard library's `HTTP::CompressHandler`. Opt-in, and not in the
  default stack: `Static` already compresses and sets its own `Content-Length`, so put `Compression` only
  in front of the router (after `Static`), not in front of `Static`.
- `Handler::HealthCheck`: opt-in, not in the default stack. `GET /health` (or `HEAD`) answers `200`, or `503`
  naming the failing checks, without reaching the router.
- The default stack includes `Static` serving `./public` relative to the working directory, with
  `fallthrough: true`. A file there shadows a route with the same path, and anything in `public/` is
  served, so keep only public files in it. HSTS follows `config.tls?`; behind a TLS-terminating proxy pass
  your own `SecurityHeaders.new(hsts: true)`.

**OpenAPI 3.1 generation** (additive). `Azu::OpenAPI.document(app, info)` builds the document from the
`Endpoint(Request, Response)` contracts at the time you call it, and `Azu::OpenAPI::Handler` serves it as JSON
(opt-in, like `HealthCheck`). See [the reference](api/openapi.md). `Azu::Routable` gains a default
`openapi_operation` that returns nil, `Router#registered_routes` and `Router::Mount#child` are new readers.
Nothing changes for an app that does not call it. A custom `Routable` that already defines a method named
`openapi_operation` is the only possible clash.

**Graceful shutdown** (behaviour fix). On SIGTERM or SIGINT, `start` stops accepting connections and waits for
the requests in flight, up to `config.shutdown_timeout` (`SHUTDOWN_TIMEOUT` seconds, default 30), before it
shuts the rest down. Before, it exited as soon as the listener closed. The restart branch of the server loop
(`e == Errno`) could never run and is gone: a failure of the listener is logged and `start` returns.
`Azu::App#stop(timeout)` does the same from code and specs (bind the server on `bind_unused_port`).
Requests that arrive on connections that stay open after the listener closed get `503` with `Connection: close`.
Only `App.default` is drained by `start`.

**Graceful shutdown of long-lived connections** (behaviour change). Open channel WebSockets are now tracked per
app: when shutdown begins each gets a close frame with code 1001, and the drain waits for the peers to answer
(within `shutdown_timeout`); before, they were neither closed nor waited for, so a client saw a dropped
connection. A socket that registers after shutdown began is closed with 1001 without `on_connect` (one registered a moment before still runs it). Streaming
responses (SSE) still count as in flight until the handler returns, but can now end promptly: `Azu.shutting_down?`
and `Azu.shutdown_signal` report the shutdown of the app serving the request. New: `App#track_socket`,
`App#shutdown_signal`, `Azu.current_app`, `Azu.with_app`. A handler that ignores the signal behaves as before.
See [Shut Down Gracefully](../how-to/deployment/graceful-shutdown.md).

**Fixes** (behaviour changes that make the code do what it documented):

- `class` endpoints are request-safe. The router holds one instance per route and a class was shared by
  concurrent requests, so a request that waited (database, service) could read the parameters of a later
  one. Each request now runs on a copy (`dup`) of the registered instance, as structs always did: state an
  endpoint object keeps in its own instance variables no longer carries over from one request to the next.
- `Cache::RedisStore` returns values: `get`, `exists?`, `delete`, `increment`, `size` and `ping` always
  answered `nil`/`false`/`0`, and the start-up check turned `store = "redis"` into a `NullStore` after its
  retries. `size` counts the keys of the database in the URL (it only looked at `db0`).
- `Handler::CORS` no longer keeps the request's `Origin` in the shared handler, so overlapping requests on
  parallel threads cannot answer with each other's `Access-Control-Allow-Origin`.
  API change: `Handler::Origin` (the struct behind `CORS`) is stateless now. `#request_origin` and
  `#origin_header?` are removed, `#match?(request)` became `#match?(origin : String)`, and `#of(request)`
  returns the request's `Origin` (or `X-Origin`) header. Code that called these directly must pass the
  origin around itself.
- `Cache::MemoryStore#increment` sets the expiry when the counter is created (it was renewed on every call,
  so a counter hit more often than its TTL never expired) and evicts the least recently used key when a new
  counter would exceed `max_size`. `MemoryStore#stats["hit_rate"]` is a real hit rate (hits / lookups); it
  used to be the fill percentage. The router's `path_cache.stats` now calls its figure `fill_percent`.
- The HTML error page renders in production for unexpected exceptions (it raised "can't wrap
  Azu::ErrorContext" and the client got a bare `500`). The development JSON `Backtrace` shows the original
  exception's message and backtrace instead of ` (Azu::Response::Error)`. Production bodies still carry no
  backtrace, request context or environment, and for exceptions that are not `Response::Error` they now
  carry a generic title and detail ("Internal Server Error") instead of the exception's message (which could
  name a database host or user); the message stays in the log and in development bodies.
- `Cache::RedisStore#increment` / `#decrement` set the TTL in one atomic Lua script, only when the key has
  none; `decrement` used to renew it on every call.
- Not changed: Azu does not cache templates (`Templates#load` asks Crinja each time).

### 0.5.28

**No breaking changes.** This version includes documentation improvements.

### 0.5.0

**Endpoint Type Parameters**

The `Endpoint` module now requires explicit type parameters:

```text
# Before (0.4.x)
struct MyEndpoint
  include Azu::Endpoint

  def call
    # ...
  end
end

# After (0.5.x)
struct MyEndpoint
  include Azu::Endpoint(MyRequest, MyResponse)

  def call : MyResponse
    # ...
  end
end
```

**Migration:**
1. Add request type as first parameter (use `EmptyRequest` for no body)
2. Add response type as second parameter
3. Add return type annotation to `call`

**Request Access**

Request objects are now accessed via generated methods:

```text
# Before
request.name

# After
my_request.name  # Method name derived from request type
create_user_request.name  # For CreateUserRequest
```

## Version 0.4.x

### 0.4.0

**Handler Interface**

Handlers now use `call_next` instead of `next.try &.call`:

```text
# Before (0.3.x)
def call(context)
  # ...
  next.try &.call(context)
end

# After (0.4.x)
def call(context)
  # ...
  call_next(context)
end
```

**Configuration**

Configuration moved from class methods to block syntax:

```text
# Before (0.3.x)
Azu.port = 8080
Azu.env = :production

# After (0.4.x)
Azu.configure do |config|
  config.port = 8080
  config.env = Environment::Production
end
```

## Version 0.3.x

### 0.3.0

**Router Changes**

Route registration moved to macros:

```text
# Before (0.2.x)
Azu.router.add("GET", "/users", UsersEndpoint)

# After (0.3.x)
struct UsersEndpoint
  include Azu::Endpoint

  get "/users"  # Route defined with macro

  def call
    # ...
  end
end
```

**Response Objects**

Responses now implement `Azu::Response` module:

```text
# Before (0.2.x)
def call
  {users: users}.to_json
end

# After (0.3.x)
struct UsersResponse
  include Azu::Response

  def render
    {users: @users}.to_json
  end
end
```

## Version 0.2.x

### 0.2.0

**WebSocket Channels**

Channel API changed from callback-based to method-based:

```text
# Before (0.1.x)
Azu.channel("/chat") do |socket, message|
  # Handle message
end

# After (0.2.x)
class ChatChannel < Azu::Channel
  PATH = "/chat"

  def on_message(message)
    # Handle message
  end
end
```

## Deprecation Notices

### Deprecated in 0.5.x

- `Azu::Handler::Base#next` - Use `call_next(context)` instead
- Implicit request types - Always specify request type parameter

### Removed in 0.5.x

- `Azu::Endpoint` without type parameters
- `Azu.start` without handler array

## Migration Tools

### Checking for Deprecations

Run the compiler in strict mode:

```bash
crystal build --warnings=all src/app.cr
```

### Version Compatibility

| Azu Version | Crystal Version |
|-------------|-----------------|
| 0.5.x | 1.19.1 and newer (CI runs 1.19.1 and the latest release) |
| 0.4.x | 0.35.0 - 1.0.0 |
| 0.3.x | 0.35.0 - 0.36.x |

## Getting Help

If you encounter issues during migration:

1. Check the [GitHub Issues](https://github.com/azutopia/azu/issues)
2. Review the [CHANGELOG](https://github.com/azutopia/azu/blob/master/CHANGELOG.md)
3. Ask in the [Crystal Forum](https://forum.crystal-lang.org/)

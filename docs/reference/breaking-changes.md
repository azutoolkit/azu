# Breaking Changes

This document lists breaking changes between Azu versions and migration guides.

## Version 0.5.x

### Unreleased (0.6 work)

Step by step, with old and new code side by side: [Migrate to 0.6](../how-to/migrate-to-0.6.md).

**`Azu::CQL.schema` runs PostgreSQL on CQL's native engine pool.** With a CQL release that has
`CQL::Postgres::EngineSource`, schemas for `postgres://` and `postgresql://` URLs use CQL's own wire driver and
`AsyncEngine` pool instead of crystal-db's pool with the `pg` shard. SQLite, MySQL and `cockroachdb://` are unchanged
(`cockroachdb://` runs on the engine only with `driver: :engine`, which is experimental: CQL checked it against CockroachDB 24.3 only).
Check these before upgrading:

- **Errors.** Server errors are `CQL::Postgres::Error` subclasses (`UniqueViolation`, `ForeignKeyViolation`,
  `SerializationFailure`, ...), not `PQ::PQError`, and not `DB::Error`. Pool errors are `CQL::Postgres::PoolTimeout` and
  `PoolClosed`. A connection that cannot be opened is still `DB::ConnectionRefused`. Migration: change
  `rescue ex : DB::Error` to `rescue ex : DB::Error | CQL::Postgres::Error` (and `PQ::PQError` to `CQL::Postgres::ServerError`).
- **Failed-query text.** The dashboard shows the SQLSTATE and the message the driver considers safe (`undefined table (SQLSTATE 42P01)`),
  not the relation or column name: the driver keeps server wording that can carry bound values out of messages. CQL could attach
  `table_name`/`column_name` metadata to the error; that is a proposal for CQL, not part of this change.
- **Decoding.** `numeric` columns decode to `CQL::Postgres::Types::DecimalText` and arrays to their text form;
  `read(Float64)` or `read(Array(Int32))` on them raises `TypeCastError`.
- **TLS and URLs.** `sslmode` accepts `disable`, `prefer`, `require` and `verify-full`. `verify-ca`, `allow`, `sslcert` and `sslkey`
  raise `ArgumentError` when the schema is created, even with `lazy: true` (the URL is parsed then). The engine keeps a literal `+`
  in a user name or password; crystal-db read `+` there as a space, so a password that relied on that must be written with a
  real space (`%20`).
- **Pool.** The pool is the engine's. Azu maps `CQL.config.pool` and crystal-db's `max_pool_size` (`0`, meaning unlimited there,
  becomes the default of 10), `initial_pool_size` (never above the pool size) and `checkout_timeout` for you. `prepared_statements=false`
  and `prepared_statements_cache=false` become `statement_cache_size=0` unless the URL sets it. `max_idle_pool_size`, `retry_attempts`,
  `retry_delay` and `auth_methods` are dropped: the engine does not retry connects. Behind a transaction-mode pooler (PgBouncer) use
  `statement_cache_size=0` (or `prepared_statements=false`). The rest of the URL is passed on byte for byte.
- **Shutdown.** `Azu.shutdown` closes the database pools: `Azu.on_shutdown` hooks run in reverse registration order between PubSub and Redis,
  and the pools close in the hook `azu/cql` registered when it was required, so hooks your app registers later run first. Handler
  fibers still serving a request when the server stops can meet a closed pool, as with Redis.
- **Opt out** per schema with `driver: :db` or for the app with `AZU_CQL_DRIVER=db`; crystal-db's pool and the registered driver (the
  `pg` shard if you require it) then serve the URL as before. `driver:` and `AZU_CQL_DRIVER` apply only to `Azu::CQL.schema`: a schema
  made directly with `CQL::Schema.define` or `.new` is unaffected. An unknown `AZU_CQL_DRIVER` value raises `ArgumentError` for every schema.
- **New:** `Azu::CQL.health_check(schema)`, `Azu::CQL.engine(schema)`, `Azu::CQL.shutdown`, `.track`/`.untrack`, `Azu.on_shutdown`. A schema made
  twice under the same name closes the first one.

**`Handler::Static` redirects to the right path.** The redirect for a directory requested without its trailing slash answered
`Location: /subdir//` (two slashes), and one for a path that was not in its normal form (`/a/../b.txt`) answered `/b.txt/` (a slash added to a
file). Now `/subdir` redirects to `/subdir/`, `/a/../b.txt` to `/b.txt`, and the query string is kept. A
`Location` always starts with exactly one `/`, so `//evil.com` can never become a protocol-relative redirect.
**Azu's error pages no longer depend on the working directory.** `error.html` and `error_debug.html` are compiled into
the binary (`Azu::Templates::BUILTIN`), and `ERROR_TEMPLATE` defaults to the directory they live in inside the azu source
(resolved at compile time) instead of `./src/azu/templates`. Before, an app that installed azu as a shard found no
error template unless it ran from a checkout of azu, so the production HTML error page raised
`Crinja::TemplateNotFoundError`. The lookup order is now your `templates.path` directories, then `ERROR_TEMPLATE`, then the
built-in pages (before: `ERROR_TEMPLATE` first), so an `error.html` in your own template directory now overrides the
built-in one. `TEMPLATES_PATH` is unchanged: it is for your templates and a relative entry is still resolved against the
working directory, so run the app from its root or set an absolute path.
`Templates#crinja.loader` is a `Crinja::Loader::ChoiceLoader` now, not a `FileSystemLoader`.

**`Azu::Env` skips many more names from a `.env` file.** The denylist is now the one the `azu` CLI uses
(`AzuCLI::DotEnv`), where it used to cover only `LD_*`, `DYLD_*`, `SHARDS_*`, `GIT_*`, `PATH`, `SHELL`, `IFS`,
`BASH_ENV`, `ENV`, `CRYSTAL_PATH`, `CRYSTAL_OPTS`, `CRYSTAL_LIBRARY_PATH`, `DOCKER_HOST` and `HOME`. It now also skips
every other `CRYSTAL_*` (but not `CRYSTAL_ENV` or `CRYSTAL_LOG_*`), `DOCKER_*`, `COMPOSE_*`, `SSH_*`, compiler and linker
variables (`CC`, `CXX`, `*FLAGS`, ...), proxy and certificate variables (`HTTP_PROXY`, `SSL_CERT_FILE`, ...), other
runtimes' variables (`PYTHON*`, `RUBY*`, `NODE_OPTIONS`, `GEM_*`, `CARGO_*`, ...), `USER`, `TMPDIR`, `XDG_*` and the
locale and time zone names `LANG`, `LC_*` and `TZ`. Matching is case-insensitive. A skipped name logs a warning naming
it (never the value) and is not set. If your `.env` sets one of them (typically `TZ` or `LANG`), set it in the real
environment instead, or load the file with `unsafe: true`. Note that `*FLAGS` also matches application names such as `FEATURE_FLAGS`, `LOG_FLAGS` and `MY_CFLAGS`: rename them (for example `FEATURES`). See [Environment](configuration/env.md#trust).

**An endpoint declared with the bare `Azu::Request` reads its params on first use.** A JSON, multipart or other
non-urlencoded body is no longer read before `call`, so a bare-`Azu::Request` endpoint that never touches `params` no
longer answers `400` or `413` for it; a large unread body is drained by `HTTP::Server` after the handler instead of
being rejected. One that reads `params` gets the error where it asks. A `POST` with a urlencoded body is still read by
the router (for `_method`) and still answers `413` before dispatch. Endpoints with a request contract (a struct that
includes `Azu::Request`) are unchanged: they parse before `call`.

**A request id is cut from a buffered chunk of secure random bytes.** The format `req_<ms>_<16 hex>` is unchanged.

**A `Static` public directory created after boot is picked up within a second**, not at once.

**A Redis cache needs an explicit URL, and `clear` only removes the cache's own keys.**

- `cache_config.redis_url` is now `String?` and has no default (it used to be `redis://localhost:6379/0`).
  `CACHE_STORE=redis` without `CACHE_REDIS_URL` (or `cache_config.redis_url`, or `cache_config.redis_client`) now
  raises an `ArgumentError` at `start` (`Configuration#prepare` checks it, without connecting) and on any use of
  `Azu.cache`; it is not turned into a disabled cache. Any other `ArgumentError` raised while the cache is built (an
  unknown `CACHE_STORE`) propagates the same way; only an unreachable Redis still falls back to a disabled cache.
  Set `CACHE_REDIS_URL`; to keep using localhost, say so: `CACHE_REDIS_URL=redis://localhost:6379/0`. `REDIS_URL`
  is not read by the cache.
- `Azu.cache.clear` removes the keys under `"<key_prefix>:"` instead of running `FLUSHDB`, so other keys in the same
  Redis database survive. Use `Azu.cache.clear(all: true)` for the old behaviour (`FLUSHDB`).
  `RedisStore#clear` used directly is still `FLUSHDB`. Limits of the prefix clear (cost, Redis version, Cluster):
  [Cache reference](api/cache.md).
- `Cache::Store` has a new abstract method `clear_prefix(prefix : String) : Bool`; a custom store must implement it.

**Path and query parameters win over the request body.** `Params#[]`, `#[]?`, `#fetch_all` and `#to_h` looked the form
body up first, then the path, then the query string, so `POST /users/5` with `id=1` in the body handed the endpoint
`id=1` (and the typed request of a form got the body's value too). The order is now path, query string, body. A JSON
body is applied the same way when the typed request is built: a path or query value replaces a key the body already
has (keeping the JSON type of the body's value); keys the body lacks are not added. Migration: an endpoint that read a
value the client was meant to override from the body must stop naming that field like a path parameter or a query key.

**The global shim is deprecated.** `include Azu`, `configure` and `start` still work, and log one warning per
process (at the first call, not when requiring azu) that names `Azu::App`.

**Per-app leftovers.** Building a configuration no longer applies its `i18n` settings to the process-wide
`Helpers::I18n` (`I18nConfiguration#apply` does, called when an app builds its server, and it passes on only the settings that
differ from the defaults, so an explicit `Helpers::I18n.configure` wins). Code that never reaches `App#server`
(router-only tests, a hand-built `HTTP::Server`) no longer gets `I18N_*` environment settings applied; call
`config.i18n.apply` yourself there. `Handler::Logger`,
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

**The development error context redacts credentials.** `Azu::ErrorContext` (the request/process data an error carries in development and
puts in the JSON, text and `error_debug.html` pages) used to hold the whole process environment and the raw request headers. The
environment is now `Azu::Env.redacted(ENV.to_h)` (values of names such as `*_SECRET`, `*_TOKEN`, `*_KEY`, `*PASSWORD*`, `*COOKIE*`, `*AUTH*` become
`[FILTERED]`, and the password of a `scheme://user:password@host` URL is hidden), the header values of `Authorization`, `Cookie`, `Set-Cookie`,
`X-CSRF-Token`, `X-API-Key` and the like are `[FILTERED]` in `to_h`/`to_json` (`ErrorContext#headers` is still the real request headers; use
`#redacted_headers` for display), and query parameters with such names are redacted in `#redacted_params`. If you read a secret value out of an
error JSON in development, read it from the environment instead.

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

**Content negotiation.** New: [`Response::Negotiable`](api/content-negotiation.md). Endpoints now write their
response with `Response#write_to(context)`, which prints `render` unless the type overrides it, so existing
responses are unchanged; a hand written response type that defines its own `write_to` is now called. The
undocumented `Azu::ContentNegotiator`, which nothing called, is removed.

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

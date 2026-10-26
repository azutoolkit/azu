# App

`Azu::App` is an application as a value: its own configuration, router, handler chain and lifecycle. Two of them
can live in one process. `include Azu` is the supported single-app facade over the same class: it drives
`Azu::App.default`, the app built around the global `Azu::CONFIG`.

```crystal
require "azu"

struct HelloEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end

app = Azu::App.new
app.config.port = 3000
app.routes { get "/hello", HelloEndpoint }

app.start # serves until SIGINT/SIGTERM or app.stop
```

## start

```crystal
require "azu"

app = Azu::App.new
handlers = [Azu::Handler::RequestId.new] of HTTP::Handler

app.start                                   # Azu::App#default_handlers
app.start(handlers)                         # the array, exactly as given
app.start(signals: false, teardown: false)  # embedded in a program (or a spec) that manages both itself
```

`default_handlers` is the default stack, in this order: `RequestId`, `Logger` (writing to `config.log`), `Rescuer`,
`SecurityHeaders` (HSTS when `config.tls?`) and `Static` (files from `public/`, falling through to the router). It
returns new instances on every call, since a handler belongs to one chain. An array you pass instead is used exactly
as given and nothing is added to it; its handlers run in the order listed, and the chain ends in the router. Endpoints
are not handlers: they are reached through the router.

`start(handlers = default_handlers, *, signals = true, teardown = true) : Nil` blocks until the app stops. It does, in order:

1. Builds the server for the handlers (`App#server`) and binds `config.host`:`config.port`, over TLS when `config.tls?`. A bind
   error (the port is taken) is raised to the caller with nothing left behind: nothing was prepared, the handlers are
   unchained, so the same array can be passed to a second `start`.
2. `prepare`: the async log pipeline, the upload temp directory and its cleanup, and the `azu/dev` hooks. Then the log
   lines about the environment and the address: one INFO when the environment is the default (`CRYSTAL_ENV` not set, see
   [Environments](../configuration/environments.md#the-default-environment)), and the WARNs about a loopback address inside
   a container (`set HOST=0.0.0.0`) or the development pages on every interface.
3. With `signals: true`, traps SIGINT and SIGTERM. A signal stops **every** app started with `start` (the trap is
   process-wide, there is one, not one per app): requests are refused with a `503`, open WebSockets get a close frame
   `1001`, streaming responses see `Azu.shutdown_signal` close, and the servers close. The trap replaces any trap the
   program installed; there is no chaining, so a program with its own signal handling passes `signals: false` and calls
   `stop` itself. The default handlers return as soon as a signal arrives (a second signal ends the process, and an app
   started while another drains installs its own trap) and when the last app stops while the trap is still ours.
   `App.signals_trapped?` tells whether the trap is in place.
4. Listens. When the server closes (a signal, or `stop`) it waits up to `config.shutdown_timeout` for the requests in
   flight and logs a warning when some were dropped.
5. With `teardown: true`, once the **last** app started this way has stopped, runs `Azu.shutdown`: Spark connections,
   presence, PubSub, the hooks registered with `Azu.on_shutdown` (in reverse order; `azu/cql` registers the closing of
   the database pools) and the shared Redis pools. These parts are process-wide, which is why one app stopping while
   another still runs leaves them alone.

**An app starts once.** `start` on a running app raises `Azu::App::AlreadyRunning`; on an app that has stopped, or has
begun shutting down (`stop`, a signal, `begin_shutdown`), it raises `Azu::App::AlreadyStopped`: a stopped app refuses
requests for good, so build a new `Azu::App` to serve again. A `start` that failed to bind does not count and can be repeated.
This holds for `Azu::App.default` too, so `MyApp.start` runs once per process.

| Signature | Returns | Notes |
|---|---|---|
| `stop(timeout = config.shutdown_timeout)` | `Bool` | Refuses new requests, closes the server and waits for the requests in flight. `true` when none was dropped. `start` returns afterwards. Safe to call twice |
| `running?` | `Bool` | True from `start` until it returns |
| `address` | `Socket::IPAddress?` | Where the server listens, once bound; with `config.port = 0` the port the system picked. nil before `start` has bound and after the server has closed |
| `begin_shutdown`, `draining?`, `drain(timeout)` | `Nil`, `Bool`, `Bool` | The pieces `stop` is made of |
| `prepare` | `Nil` | What `start` does before it binds; `Azu.prepare` is `App.default.prepare` |
| `routes(&)` | `Nil` | Declares the app's routes: the verbs, `ws`, `scope` and `mount` (see [Router](router.md)) |
| `router` | `Router` | `config.router` |
| `server(handlers = [] of HTTP::Handler)` | `HTTP::Server` | The app's chain for `handlers` in an `HTTP::Server` you drive yourself: it is not bound or started. `stop` closes the server built last |
| `default_handlers` | `Array(HTTP::Handler)` | The default stack, new instances on every call |

An app on an ephemeral port, as the specs of Azu run it:

```crystal
require "azu"
require "http/client"

struct HelloEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end

app = Azu::App.new
app.config.host = "127.0.0.1"
app.config.port = 0
app.routes { get "/hello", HelloEndpoint }

spawn { app.start(signals: false, teardown: false) }
until app.address
  sleep 10.milliseconds
end
address = app.address.not_nil!

HTTP::Client.get("http://#{address.address}:#{address.port}/hello")
app.stop
```

## Several apps in one process

Each `Azu::App` has its own configuration and router, so two can listen on two ports with different routes. Their
handler chains are separate: build new handler instances for each (a handler belongs to one chain), which
`default_handlers` does. What stays shared is listed in [Migrate to 0.6](../../how-to/migrate-to-0.6.md#still-shared-between-apps):
`Channel.ws`, PubSub, Spark connections, `QueryStore`, the helper and i18n registries.

## Mounting

`mount` serves another app below a prefix of this one. Only the app that owns the server is started; the mounted
app's routes are reached through its router, with its own configuration, and it is **not** started on its own:

```crystal
require "azu"

struct UsersEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end

admin = Azu::App.new
admin.routes { get "/users", UsersEndpoint }

app = Azu::App.new
app.routes { mount admin, at: "/admin" } # GET /admin/users
app.start
```

An app can be mounted once. `Endpoint.path` includes the prefix. See [Router](router.md).

## The include Azu facade

```crystal
require "azu"

module MyApp
  include Azu

  configure { |config| config.port = 3000 }
end

MyApp.start # Azu::App.default.start
```

`include Azu` is supported, not deprecated: it logs no warning and nothing about it is scheduled for removal. It is the
shortest way to run one application. `MyApp.start` and `MyApp.start(handlers)` are `Azu::App.default.start` with the
default arguments, so there is one lifecycle and one code path. Its limits are what the name says:

- `configure`, `MyApp.config` and `Azu::CONFIG` are the one global configuration. A process has one facade app; run a
  second application as an `Azu::App.new` and `start` it.
- The endpoint verb macros (`get "/x"` inside an endpoint) register on that global app.
- The facade does not pass `signals:` or `teardown:`; call `Azu::App.default.start(handlers, signals: false)` for those.

Everything on this page works on `Azu::App.default` too (`Azu::App.default.stop`, `.address`, `.running?`).

## The Azu module

`require "azu"` defines the `Azu` module. A module that includes it gets the facade methods, which act on
`Azu::CONFIG` and `Azu::App.default`. The module functions are called on `Azu` itself, and most of them answer for
the app serving the current fiber's request. The options `configure` sets are on
[Configuration options](../configuration/options.md), and the `Azu::Environment` members and their predicates on
[Environments](../configuration/environments.md).

```crystal
require "azu"

module MyApp
  include Azu

  configure do |config|
    config.port = 8080
    config.shutdown_timeout = 10.seconds
  end
end

MyApp.log.info { "starting in #{MyApp.env}" }
MyApp.config.router.route_info # the registered routes
Azu.cache.set("greeting", "hello", ttl: 1.hour)
Azu.on_shutdown { MyApp.log.info { "stopped" } }

MyApp.start
```

### Facade methods

| Signature | Returns | Notes |
|---|---|---|
| `configure(&)` | the block's value | Yields `Azu::CONFIG`, as the block argument and as the receiver of calls without one |
| `config` | `Configuration` | `Azu::CONFIG`. `config.router.route_info` lists the registered routes, one `Hash(String, String)` each with `"method"`, `"path"`, `"resource"`, `"handler"` and `"description"` |
| `env` | `Environment` | `Azu::CONFIG.env`, so `MyApp.env.production?` |
| `log` | `Log` | `Azu::CONFIG.log`, the logger the framework writes to |
| `start` | `Nil` | `Azu::App.default.start`: the default handlers, signals trapped, teardown on (see [start](#start)) |
| `start(handlers : Array(HTTP::Handler))` | `Nil` | `Azu::App.default.start(handlers)`: the array exactly as given |

### Module functions

| Signature | Returns | Notes |
|---|---|---|
| `Azu.current_config` | `Configuration` | The configuration of the app serving the current fiber's request, or the one `with_config` set; `Azu::CONFIG` otherwise |
| `Azu.with_config(config : Configuration, &)` | the block's value | Runs the block with `config` as `current_config` for this fiber. Scopes nest: leaving one restores the configuration that was current before. For tests |
| `Azu.clear_fiber_configs` | `Nil` | Drops the configuration every fiber set with `with_config` (a fiber's current app stays). For test suites |
| `Azu.current_app` | `App?` | The app serving the request this fiber handles (a mounted app's requests belong to the app that owns the server); nil outside one |
| `Azu.with_app(app : App?, &)` | the block's value | Runs the block with `app` as `current_app`; a nil `app` leaves things as they are |
| `Azu.spawn_scoped(name : String? = nil, &block : ->)` | `Fiber` | `spawn`, but the new fiber keeps the current app and configuration; a plain `spawn` starts with the global ones. For work that outlives the request (timers, WebSocket heartbeats) |
| `Azu.shutting_down?` | `Bool` | True once the app serving this request has begun shutting down (SIGINT, SIGTERM or `begin_shutdown`) |
| `Azu.shutdown_signal` | `::Channel(Nil)` | Closed when the app serving this request begins shutting down, for `select when Azu.shutdown_signal.receive?`. Outside an app it never closes |
| `Azu.mounted_path(endpoint : Routable.class, fallback : String = "")` | `String` | The endpoint's path in the app being served, with the prefix that app is mounted at; `fallback` when the current router does not route the endpoint |
| `Azu.cache` | `Cache::Manager` | `current_config.cache`: `set(key, value, ttl:)`, `get`, `delete` (see [Cache](cache.md)) |
| `Azu.setup_logging` | `Nil` | Installs Azu's log format at the `Debug` level for the whole process. Opt-in: neither `require "azu"` nor `start` touches `Log` |
| `Azu.prepare` | `Nil` | `Azu::App.default.prepare` |
| `Azu.on_shutdown(&block : ->)` | `Nil` | Registers a hook for `Azu.shutdown`. Hooks run in reverse order of registration; one that raises is logged and does not stop the others |
| `Azu.shutdown` | `Nil` | Closes Spark connections, the default presence tracker, the PubSub backend, the `on_shutdown` hooks and, last, the shared Redis pools. `start` calls it once the last app has stopped (with `teardown: true`); safe to call again |

### Constants

| Constant | Type | Notes |
|---|---|---|
| `Azu::CONFIG` | `Configuration` | The global configuration, built when `azu` is required; `Azu::App.default.config` |
| `Azu::VERSION` | `String` | The release version, read from `shard.yml` at compile time |
| `Azu::Validator` | alias | `Schema::Validator`, the base class of a [custom validator](request.md#custom-validators) |

## Known limitations

- **A signal while `start` is coming up.** `start` registers the app as running, binds the port and only then installs the
  SIGINT/SIGTERM trap (when no other app's trap is in place). If another app's trap is in place, a signal that arrives
  after the registration and before the bind marks this app as shutting down too, so a retry of its `start` raises
  `AlreadyStopped`: build a new `Azu::App` for the retry. With no trap in place the default handler ends the process, as
  for any program. The window is the few milliseconds of the bind.
- **The dashboard's SQL path in the CSRF exemptions.** Building a `Handler::DevDashboard` adds `{path}/sql` to the
  process-wide `Handler::CSRF.exempt` list in every environment (the handler is built before the app that will serve it
  is known). The exemption is inert while the dashboard passes requests on, which is everywhere except development, but
  it stays in the list: a route of your own at the same path is exempt from CSRF checks too.

## See also

- [Configuration options](../configuration/options.md)
- [Router](router.md)
- [Environments](../configuration/environments.md)
- [Testing](testing.md): drive an app in process, without a socket

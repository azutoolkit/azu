# App Reference

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

| Method | |
|---|---|
| `stop(timeout = config.shutdown_timeout) : Bool` | Refuses new requests, closes the server and waits for the requests in flight. `true` when none was dropped. `start` returns afterwards. Safe to call twice |
| `running? : Bool` | True from `start` until it returns |
| `address : Socket::IPAddress?` | Where the server listens, once bound; with `config.port = 0` the port the system picked. nil before `start` has bound and after the server has closed |
| `begin_shutdown`, `draining?`, `drain(timeout)` | The pieces `stop` is made of |
| `prepare : Nil` | What `start` does before it binds; `Azu.prepare` is `App.default.prepare` |

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

## See Also

- [Core API](core.md)
- [Router](router.md)
- [Environments](../configuration/environments.md)
- [Testing](testing.md): drive an app in process, without a socket

# Migrate to 0.6

0.6 makes an application a value: `Azu::App` owns a configuration and a router, and nothing starts
when you `require "azu"`. The global shim (`include Azu`, `configure`, `Azu::CONFIG`, the endpoint
verb macros) still works and drives `Azu::App.default`, but it is deprecated: the first call to
`configure` or `start` logs one warning per process naming `Azu::App`. This page shows each old
form next to its replacement. The full list of behaviour changes is in
[breaking changes](../reference/breaking-changes.md).

## Configuration

Before, one global configuration:

```crystal
require "azu"

module MyApp
  include Azu

  configure do |config|
    config.port = 3000
  end
end
```

After, a configuration that belongs to an app:

```crystal
require "azu"

app = Azu::App.new
app.config.port = 3000
app.config.env = Azu::Environment::Production
```

Code that runs while a request is handled finds the serving app's configuration with
`Azu.current_config`; use it instead of reading `Azu::CONFIG`.

## Routes and endpoints

An endpoint no longer needs a verb macro. Declare the route on the app:

```crystal
require "azu"

struct HelloRequest
  include Azu::Request

  getter name : String = "World"
end

struct HelloResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    "Hello, #{@name}!"
  end
end

struct HelloEndpoint
  include Azu::Endpoint(HelloRequest, HelloResponse)

  def call : HelloResponse
    HelloResponse.new(hello_request.name)
  end
end

app = Azu::App.new
app.routes do
  get "/", HelloEndpoint
  scope "/api" do
    get "/hello", HelloEndpoint
  end
end
```

The verb macros (`get "/"` inside an endpoint) keep registering on `Azu::App.default`, because an
endpoint type is not tied to an app. That is a known limit of 0.6: use `app.routes` for any app that
is not the default one. `Channel.ws` is global in the same way, while `ws` inside `app.routes` is
per app.

A second app can be mounted below a prefix with its own configuration:

```crystal
require "azu"

admin = Azu::App.new
main = Azu::App.new
main.routes do
  mount admin, at: "/admin"
end
```

## Handlers

Pass the handlers when you build the server. Without an argument you get the default stack
(`RequestId, Logger, Rescuer, SecurityHeaders, Static`); an array is used exactly as given.

```crystal
require "azu"

app = Azu::App.new
handlers = [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
] of HTTP::Handler
server = app.server(handlers)
```

`Handler::Logger`, `SimpleLogger` and `Throttle` log to the app that serves the request when you do not
pass `log:`; pass one to choose a log yourself. Each handler instance belongs to one chain, so build
new ones for every app.

## Start and shutdown

Before, `MyApp.start` bound the port, trapped signals and blocked. With an app you do those steps:

```crystal
require "azu"

app = Azu::App.new
server = app.server(app.default_handlers)
server.bind_tcp app.config.host, app.config.port

Signal::TERM.trap do
  app.stop
end

Azu.prepare
server.listen
Azu.shutdown
```

`app.stop(timeout)` stops accepting connections and waits for the requests in flight, up to
`config.shutdown_timeout`. `MyApp.start` still does all of this for `Azu::App.default`.

## Logging

`require "azu"` and `start` no longer configure `Log`. Call `Azu.setup_logging` once at boot if you want
Azu's format at `Debug`.

```crystal
require "azu"

Azu.setup_logging
```

## Dev tools

The dashboard and performance monitor are opt-in. Require them after `azu` and add the handlers to
the chain in development only:

```crystal
require "azu"
require "azu/dev"

app = Azu::App.new
handlers = [] of HTTP::Handler
if app.config.env.development?
  handlers << Azu::Handler::DevDashboard.new
  handlers << Azu::Handler::PerformanceMonitor.new
end
server = app.server(handlers)
```

## Contracts answer 422

An endpoint whose request type has validations no longer runs when the request breaks them: the router
answers `422` with an RFC 7807 `application/problem+json` body before `call`. To keep the pre-0.6 body
for one more minor release:

```crystal
require "azu"

app = Azu::App.new
app.config.error_format = Azu::ErrorFormat::Legacy
```

Endpoints that validated by hand and re-rendered a form should declare a request type without
validations.

## Still shared between apps

These are process-wide in 0.6 and are not per app: the endpoint verb macros, `Channel.ws`, the PubSub
backend, Spark connections, `QueryStore`, the helper and i18n registries (the last app to build a
server applies the `i18n` settings that differ from the defaults, and an explicit
`Azu::Helpers::I18n.configure` is never overwritten), `Azu.prepare` and `Azu.shutdown` (they use the global
`Azu::CONFIG`), the dev handlers' `log:` default, and `Handler::Static`
when built by hand (its `cache_max_age` defaults to the global configuration; `app.default_handlers`
passes the app's).

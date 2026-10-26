# Migrate to 0.6

0.6 makes an application a value: `Azu::App` owns a configuration and a router, and nothing starts
when you `require "azu"`. The global shim (`include Azu`, `configure`, `Azu::CONFIG`, the endpoint
verb macros) is a supported single-app facade: it drives `Azu::App.default`, logs no warning and is not
scheduled for removal. It keeps one global configuration, so a process has one facade app; move to
`Azu::App` when you need a second app, a configuration that is not global, or an app you start from code.
The full list of behaviour changes is in [breaking changes](../reference/breaking-changes.md).

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

Pass the handlers when you build the server; an array is used exactly as given. `app.server` without an argument
serves the router with no handlers in front of it: no request id, logging or error pages. Only `start` without an
argument uses the default stack, `app.default_handlers` (`RequestId, Logger, Rescuer, SecurityHeaders, Static`).

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

Before, only `MyApp.start` bound the port, trapped signals and blocked, so an app built as a value had to repeat those
steps by hand. `Azu::App#start` does them, and `MyApp.start` is `Azu::App.default.start`:

```crystal
require "azu"

app = Azu::App.new
app.config.port = 3000
app.start
```

`app.stop(timeout)` stops accepting connections and waits for the requests in flight, up to
`config.shutdown_timeout`; `start` returns afterwards, after `Azu.shutdown` (database pools, Redis, `Azu.on_shutdown`
hooks) when it was the last app running. See [App](../reference/api/app.md#start) for `signals:` and `teardown:`, and for
several apps in one process.

If you built the server yourself (`app.server`, `bind_tcp`, `listen`), that keeps working; you call `Azu.prepare`,
`Signal::TERM.trap { app.stop }` and `Azu.shutdown` yourself, as before.

## Logging

`require "azu"` and `start` no longer configure `Log`. Call `Azu.setup_logging` once at boot if you want
Azu's format at `Debug`.

```crystal
require "azu"

Azu.setup_logging
```

## Dev tools

The dashboard and performance monitor are opt-in. Require them after `azu` and add the handlers to
the chain in development only, after the default stack so the request id, logging and error pages stay:

```crystal
require "azu"
require "azu/dev"

app = Azu::App.new
handlers = app.default_handlers
if app.config.env.development?
  handlers << Azu::Handler::DevDashboard.new
  handlers << Azu::Handler::PerformanceMonitor.new
end
server = app.server(handlers)
```

## Contracts answer 422

An endpoint whose request type has validations no longer runs when the request breaks them: the endpoint
answers `422` itself, before `call`. The first `Accept` entry picks the format of the body: a JSON client gets an
RFC 7807 problem body (`application/problem+json` when it names that type, `application/json` otherwise), `text/html`
an HTML page, an XML type XML, and a request without `Accept`, or with `*/*`, `text/plain`. To keep the pre-0.6 body
for one more minor release:

```crystal
require "azu"

app = Azu::App.new
app.config.error_format = Azu::ErrorFormat::Legacy
```

Endpoints that validated by hand and re-rendered a form should declare a request type without
validations.

## Templates are autoescaped

`.jinja`, `.j2` and string templates escape `{{ }}` output like `.html` (JSON, JavaScript, CSS, Markdown, YAML, SQL, shell
and plain text templates excluded). Check three things:

1. Markup you print on purpose needs `| safe`: `{{ spark_html | safe }}` for `Azu::Spark.render` and `Azu::Spark.script_tag`
   output, and for `t()` values that contain HTML. The built-in helpers and `csrf_tag` / `csrf_metatag` are safe already.
2. `{{ x | e }}` still works and does not escape twice. Filters that rebuild the string (`upper`, `lower`, `title`,
   `truncate`, `replace`, `format`, the `~` operator) return plain text: `{{ (x | e) | upper }}` prints `&amp;LT;`. Put
   `| e` or `| safe` last.
3. Your own helpers that return HTML must return `Crinja::SafeString.new(html)`.

```jinja
{{ csrf_metatag }}              {# safe: a template variable #}
{{ spark_html | safe }}         {# a String from Azu::Spark.render #}
{{ (title | upper) | e }}       {# transform first, mark last #}
```

`template_autoescape = false` (or `TEMPLATE_AUTOESCAPE=false`) restores the old behavior while you migrate; the start logs a
warning. See [Breaking changes](../reference/breaking-changes.md).

## Still shared between apps

These are process-wide in 0.6 and are not per app: the endpoint verb macros, `Channel.ws`, the PubSub
backend, Spark connections, `QueryStore`, the helper and i18n registries (the last app to build a
server applies the `i18n` settings that differ from the defaults, and an explicit
`Azu::Helpers::I18n.configure` is never overwritten), `Azu.shutdown` (and `Azu.prepare`, which prepares `Azu::App.default`), the dev handlers' `log:` default, and `Handler::Static`
when built by hand (its `cache_max_age` defaults to the global configuration; `app.default_handlers`
passes the app's).

# Core module

The `Azu` module is the main entry point for creating Azu applications.

## Including Azu

```crystal
module MyApp
  include Azu
end
```

## Configuration

### configure

Configure application settings. `configure` yields the configuration, so settings are assigned on the block argument.

```crystal
module MyApp
  include Azu

  configure do |config|
    config.port = 8080
    config.host = "0.0.0.0"
    config.env = Azu::Environment::Production
    config.template_hot_reload = false
    config.shutdown_timeout = 10.seconds
  end
end
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `port` | `Int32` | `PORT` or `4000` | HTTP server port |
| `host` | `String` | `HOST`, else `"127.0.0.1"` in development and `"0.0.0.0"` elsewhere | Bind address |
| `env` | `Azu::Environment` | `CRYSTAL_ENV` or `Development` | Environment mode |
| `template_hot_reload` | `Bool` | `true` in development, test and pipeline | Reload templates on change |
| `log` | `Log` | `Log.for("Azu")` | Logger used by the framework |
| `cache` | `Azu::Cache::Manager` | memory store | Cache manager (see [cache](#cache)) |
| `shutdown_timeout` | `Time::Span` | `SHUTDOWN_TIMEOUT` or `30` seconds | How long a stopping server waits for requests in flight |
| `error_format` | `Azu::ErrorFormat` | `Problem` | Body of JSON error responses: validation failures and every other `Response::Error` (`Problem` or `Legacy`) |

See the [Configuration Reference](../configuration/options.md) for the rest.

## Environment

`Azu::Environment` has these members, in this order:

<!-- skip -->
```crystal
enum Environment
  Build
  Development
  Test
  Integration
  Acceptance
  Pipeline
  Staging
  Production
end
```

### Checking Environment

```crystal
module MyApp
  include Azu
end

if MyApp.env.production?
  # Production-only code
end

MyApp.env.development? # => Bool
MyApp.env.test?        # => Bool
```

## Starting the Application

### start

Start the HTTP server: `MyApp.start` is `Azu::App.default.start` (see [App](app.md#start)). Without arguments it serves
the default handler stack (`RequestId`, `Logger`, `Rescuer`, `SecurityHeaders` and `Static`), and it shuts down
gracefully on `SIGTERM` and `SIGINT`, waiting up to `shutdown_timeout` for requests in flight.

```crystal
module MyApp
  include Azu
end

MyApp.start
```

### start (handlers)

Pass an array to choose the handlers yourself. It is used exactly as given and nothing is added to it.

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
] of HTTP::Handler
```

**Parameters:**
- `handlers : Array(HTTP::Handler)` - Handler chain, run in the order listed. Endpoints are not handlers: they are reached through the router.

## Apps

`Azu::App` is an application as a value: its own configuration and router. `include Azu` and the
endpoint macros drive `Azu::App.default`, the app built around the global `Azu::CONFIG`: a supported facade for a
single app per process. `app.start` serves any app, see [App](app.md).

```crystal
struct PingEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/ping"

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end

app = Azu::App.new
app.routes do
  get "/ping", PingEndpoint
  scope "/api" do
    get "/ping", PingEndpoint
  end
end

admin = Azu::App.new
admin.routes { get "/ping", PingEndpoint }
app.routes { mount admin, at: "/admin" }

server = app.server([Azu::Handler::RequestId.new] of HTTP::Handler) # an HTTP::Server you drive yourself
app.start                                                             # or the whole lifecycle
```

See [Router Reference](router.md) for `scope` and `mount`.

## Cache Access

### cache

Access the configured cache store. Time to live is a `Time::Span` passed as `ttl`.

```crystal
Azu.cache.set("key", "value", ttl: 1.hour)
Azu.cache.get("key") # => "value"
Azu.cache.delete("key")
```

## Router Access

### router

The router belongs to the configuration. `route_info` lists the registered routes.

```crystal
module MyApp
  include Azu
end

MyApp.config.router.route_info # => Array of hashes with "method", "path" and "handler"
```

## Logging

### log

Access the application logger.

```crystal
module MyApp
  include Azu
end

MyApp.log.info { "Application started" }

begin
  raise "boom"
rescue ex
  MyApp.log.error(exception: ex) { "Error occurred" }
end
```

## See Also

- [Endpoint Reference](endpoint.md)
- [Handler Reference](../handlers/built-in.md)
- [Configuration Reference](../configuration/options.md)

# Core Module Reference

The `Azu` module is the main entry point for creating Azu applications.

## Including Azu

```crystal
module MyApp
  include Azu
end
```

## Configuration

### configure

Configure application settings.

```crystal
Azu.configure do |config|
  config.port = 8080
  config.host = "0.0.0.0"
  config.env = Environment::Production
  config.template_hot_reload = false
end
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `port` | `Int32` | `4000` | HTTP server port |
| `host` | `String` | `"0.0.0.0"` | Bind address |
| `env` | `Environment` | `Development` | Environment mode |
| `template_hot_reload` | `Bool` | `true` | Reload templates on change |
| `log` | `Log::Severity` | `Debug` | Log level |
| `cache` | `Cache::Store` | `MemoryStore` | Cache backend |

## Environment

```crystal
enum Environment
  Development
  Test
  Production
end
```

### Checking Environment

```crystal
if Azu.env.production?
  # Production-only code
end

Azu.env.development?  # => Bool
Azu.env.test?         # => Bool
```

## Starting the Application

### start

Start the HTTP server with handlers.

```crystal
MyApp.start [
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  MyEndpoint.new,
]
```

**Parameters:**
- `handlers : Array(HTTP::Handler)` - Handler chain

### start (block)

Start with a block for additional setup.

```crystal
MyApp.start do |server|
  server.bind_tcp("0.0.0.0", 8080)
  server.listen
end
```

## Cache Access

### cache

Access the configured cache store.

```crystal
Azu.cache.set("key", "value", expires_in: 1.hour)
Azu.cache.get("key")  # => "value"
Azu.cache.delete("key")
```

## Router Access

### router

Access the application router.

```crystal
Azu.router.routes  # => Array of registered routes
```

## Logging

### log

Access the application logger.

```crystal
Azu.log.info { "Application started" }
Azu.log.error(exception: ex) { "Error occurred" }
```

## Type Aliases

```crystal
alias EmptyRequest = Azu::Request::Empty
alias Params = Hash(String, String)
```

## Constants

```crystal
VERSION = "0.5.28"
```

## See Also

- [Endpoint Reference](endpoint.md)
- [Handler Reference](../handlers/built-in.md)
- [Configuration Reference](../configuration/options.md)

# Configuration Options Reference

Complete reference for all Azu configuration options.

## Configuring Azu

```crystal
Azu.configure do |config|
  # Set options here
end
```

## Server Options

### port

HTTP server port.

```crystal
config.port = 8080
```

- **Type:** `Int32`
- **Default:** `4000`
- **Environment:** `PORT`

### host

Bind address.

```crystal
config.host = "0.0.0.0"
```

- **Type:** `String`
- **Default:** `"0.0.0.0"`
- **Environment:** `HOST`

### ssl

SSL/TLS configuration.

```crystal
config.ssl = {
  cert: "/path/to/cert.pem",
  key: "/path/to/key.pem"
}
```

- **Type:** `NamedTuple(cert: String, key: String)?`
- **Default:** `nil`
- **Environment:** `SSL_CERT`, `SSL_KEY`

### reuse_port

Enable SO_REUSEPORT for multiple processes.

```crystal
config.reuse_port = true
```

- **Type:** `Bool`
- **Default:** `false`

## Environment

### env

Application environment.

```crystal
config.env = Azu::Environment::Production
```

- **Type:** `Azu::Environment`
- **Default:** `Development`
- **Values:** `Development`, `Test`, `Production`
- **Environment:** `AZU_ENV`

## Logging

### log.level

Log severity level.

```crystal
config.log.level = Log::Severity::Info
```

- **Type:** `Log::Severity`
- **Default:** `Debug` (development), `Info` (production)
- **Values:** `Trace`, `Debug`, `Info`, `Notice`, `Warn`, `Error`, `Fatal`

### log.backend

Custom log backend.

```crystal
config.log.backend = Log::IOBackend.new(File.new("app.log", "a"))
```

- **Type:** `Log::Backend`
- **Default:** `Log::IOBackend.new(STDOUT)`

## Template Options

### template_path

Directory for template files.

```crystal
config.template_path = "./views"
```

- **Type:** `String`
- **Default:** `"./views"`

### template_hot_reload

Reload templates on each request.

```crystal
config.template_hot_reload = true
```

- **Type:** `Bool`
- **Default:** `true` (development), `false` (production)

## Cache Options

### cache

Cache store instance.

```crystal
config.cache = Azu::Cache::RedisStore.new(url: ENV["REDIS_URL"])
```

- **Type:** `Azu::Cache::Store`
- **Default:** `Azu::Cache::MemoryStore.new`

## Router Options

### router.path_cache_size

Number of paths to cache.

```crystal
config.router.path_cache_size = 1000
```

- **Type:** `Int32`
- **Default:** `1000`

### router.path_cache_enabled

Enable path caching.

```crystal
config.router.path_cache_enabled = true
```

- **Type:** `Bool`
- **Default:** `true`

## Request Options

### max_request_size

Maximum request body size.

```crystal
config.max_request_size = 10 * 1024 * 1024  # 10 MB
```

- **Type:** `Int32`
- **Default:** `8 * 1024 * 1024` (8 MB)

### request_timeout

Request timeout.

```crystal
config.request_timeout = 30.seconds
```

- **Type:** `Time::Span`
- **Default:** `60.seconds`

## Environment Variables

Azu reads these environment variables:

| Variable | Config Option | Description |
|----------|--------------|-------------|
| `PORT` | `port` | Server port |
| `HOST` | `host` | Bind address |
| `AZU_ENV` | `env` | Environment |
| `SSL_CERT` | `ssl.cert` | SSL certificate path |
| `SSL_KEY` | `ssl.key` | SSL key path |
| `REDIS_URL` | Cache URL | Redis connection |
| `DATABASE_URL` | Database | DB connection |

## Environment-Based Configuration

```crystal
Azu.configure do |config|
  # Common settings
  config.port = ENV.fetch("PORT", "4000").to_i

  case ENV.fetch("AZU_ENV", "development")
  when "production"
    config.env = Azu::Environment::Production
    config.log.level = Log::Severity::Info
    config.template_hot_reload = false
    config.cache = Azu::Cache::RedisStore.new(url: ENV["REDIS_URL"])

  when "test"
    config.env = Azu::Environment::Test
    config.log.level = Log::Severity::Warn
    config.port = 4001

  else # development
    config.env = Azu::Environment::Development
    config.log.level = Log::Severity::Debug
    config.template_hot_reload = true
    config.cache = Azu::Cache::MemoryStore.new
  end
end
```

## Complete Example

```crystal
Azu.configure do |config|
  # Server
  config.port = ENV.fetch("PORT", "8080").to_i
  config.host = ENV.fetch("HOST", "0.0.0.0")
  config.reuse_port = true

  # Environment
  config.env = Azu::Environment::Production

  # SSL
  if ENV["SSL_CERT"]? && ENV["SSL_KEY"]?
    config.ssl = {
      cert: ENV["SSL_CERT"],
      key: ENV["SSL_KEY"]
    }
  end

  # Logging
  config.log.level = Log::Severity::Info
  config.log.backend = JsonLogBackend.new(STDOUT)

  # Templates
  config.template_path = "./views"
  config.template_hot_reload = false

  # Cache
  config.cache = Azu::Cache::RedisStore.new(
    url: ENV["REDIS_URL"],
    pool_size: 10,
    namespace: "myapp:production"
  )

  # Router
  config.router.path_cache_size = 2000

  # Request limits
  config.max_request_size = 20 * 1024 * 1024
  config.request_timeout = 30.seconds
end
```

## See Also

- [Environments Reference](environments.md)
- [Core Reference](../api/core.md)

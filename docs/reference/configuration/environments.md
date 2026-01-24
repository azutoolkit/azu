# Environments Reference

Azu supports three environments with different default behaviors.

## Environment Enum

```crystal
enum Azu::Environment
  Development
  Test
  Production
end
```

## Setting Environment

### Via Configuration

```crystal
Azu.configure do |config|
  config.env = Azu::Environment::Production
end
```

### Via Environment Variable

```bash
export AZU_ENV=production
```

## Checking Environment

```crystal
if Azu.env.production?
  # Production-only code
end

Azu.env.development?  # => Bool
Azu.env.test?         # => Bool
Azu.env.production?   # => Bool
```

## Development Environment

Default settings for development:

| Setting | Value | Purpose |
|---------|-------|---------|
| Log level | `Debug` | Detailed logging |
| Template hot reload | `true` | Immediate changes |
| Error pages | Detailed | Full stack traces |
| Cache | Memory | Simple, local |

### Behavior

- Detailed error pages with stack traces
- Templates reloaded on each request
- Verbose logging of all requests
- Development-friendly error messages

### Configuration

```crystal
config.env = Azu::Environment::Development
config.log.level = Log::Severity::Debug
config.template_hot_reload = true
```

## Test Environment

Default settings for testing:

| Setting | Value | Purpose |
|---------|-------|---------|
| Log level | `Warn` | Less noise |
| Template hot reload | `false` | Faster tests |
| Error pages | Simple | JSON errors |
| Cache | Memory | Isolated |

### Behavior

- Minimal logging to reduce noise
- Cached templates for speed
- JSON error responses
- Isolated test database

### Configuration

```crystal
config.env = Azu::Environment::Test
config.log.level = Log::Severity::Warn
config.template_hot_reload = false
```

### Test Setup

```crystal
# spec/spec_helper.cr
ENV["AZU_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3://./test.db"

Spec.before_each do
  # Reset database
  TestDatabase.truncate_all
end
```

## Production Environment

Default settings for production:

| Setting | Value | Purpose |
|---------|-------|---------|
| Log level | `Info` | Important events |
| Template hot reload | `false` | Performance |
| Error pages | Simple | Security |
| Cache | Redis | Distributed |

### Behavior

- Minimal, structured logging
- Compiled and cached templates
- Generic error messages (no stack traces)
- External cache (Redis)
- SSL recommended

### Configuration

```crystal
config.env = Azu::Environment::Production
config.log.level = Log::Severity::Info
config.template_hot_reload = false
config.cache = Azu::Cache::RedisStore.new(url: ENV["REDIS_URL"])
```

### Security Considerations

- Stack traces hidden from users
- Sensitive data not logged
- HTTPS enforced
- Security headers enabled

## Environment Files

### .env Files

```bash
# .env.development
AZU_ENV=development
PORT=4000
DATABASE_URL=sqlite3://./dev.db

# .env.test
AZU_ENV=test
PORT=4001
DATABASE_URL=sqlite3://./test.db

# .env.production (never commit!)
AZU_ENV=production
PORT=8080
DATABASE_URL=postgres://user:pass@host/db
REDIS_URL=redis://redis:6379/0
SECRET_KEY=actual-secret
```

### Loading Environment

```crystal
# Load environment file based on AZU_ENV
env_file = ".env.#{ENV.fetch("AZU_ENV", "development")}"
if File.exists?(env_file)
  File.each_line(env_file) do |line|
    next if line.starts_with?("#") || line.blank?
    key, value = line.split("=", 2)
    ENV[key.strip] = value.strip
  end
end
```

## Complete Example

```crystal
module MyApp
  include Azu

  configure do
    env_name = ENV.fetch("AZU_ENV", "development")

    case env_name
    when "production"
      config.env = Environment::Production
      config.port = ENV.fetch("PORT", "8080").to_i
      config.host = "0.0.0.0"

      # Logging
      config.log.level = Log::Severity::Info
      config.log.backend = JsonLogBackend.new(STDOUT)

      # Templates
      config.template_hot_reload = false

      # Cache
      config.cache = Cache::RedisStore.new(
        url: ENV["REDIS_URL"],
        namespace: "myapp:prod"
      )

      # SSL
      if ssl_cert = ENV["SSL_CERT"]?
        config.ssl = {cert: ssl_cert, key: ENV["SSL_KEY"]}
      end

    when "test"
      config.env = Environment::Test
      config.port = 4001
      config.log.level = Log::Severity::Warn
      config.template_hot_reload = false
      config.cache = Cache::MemoryStore.new

    else # development
      config.env = Environment::Development
      config.port = 4000
      config.log.level = Log::Severity::Debug
      config.template_hot_reload = true
      config.cache = Cache::MemoryStore.new
    end
  end
end
```

## See Also

- [Configuration Options](options.md)
- [How to Configure Production](../../how-to/deployment/configure-production.md)

# How to Configure Production

This guide shows you how to configure your Azu application for production deployment.

## Environment Configuration

Use environment variables for all settings:

```crystal
module MyApp
  include Azu

  configure do
    port = ENV.fetch("PORT", "8080").to_i
    host = ENV.fetch("HOST", "0.0.0.0")

    case ENV.fetch("AZU_ENV", "development")
    when "production"
      log.level = Log::Severity::Info
      template_hot_reload = false
    when "test"
      log.level = Log::Severity::Warn
    else
      log.level = Log::Severity::Debug
      template_hot_reload = true
    end
  end
end
```

## Environment Variables

Create a `.env.example` file (commit this):

```bash
# Application
AZU_ENV=production
PORT=8080
HOST=0.0.0.0

# Database
DATABASE_URL=postgres://user:password@localhost:5432/myapp_prod

# Cache
REDIS_URL=redis://localhost:6379/0

# Security
SECRET_KEY=your-secret-key-here
JWT_SECRET=your-jwt-secret

# External Services
SMTP_HOST=smtp.example.com
SMTP_PORT=587
```

Create `.env.production` (never commit):

```bash
AZU_ENV=production
PORT=8080
DATABASE_URL=postgres://user:actualpassword@db.example.com:5432/myapp_prod
REDIS_URL=redis://redis.example.com:6379/0
SECRET_KEY=actual-production-secret
```

## Build for Production

Create an optimized release build:

```bash
# Build with release optimizations
crystal build --release --no-debug src/app.cr -o bin/app

# Static linking (Alpine/Docker)
crystal build --release --static --no-debug src/app.cr -o bin/app
```

## SSL Configuration

Configure SSL in your application:

```crystal
Azu.configure do |config|
  if ENV["SSL_CERT"]? && ENV["SSL_KEY"]?
    config.ssl = {
      cert: ENV["SSL_CERT"],
      key: ENV["SSL_KEY"]
    }
  end
end
```

## Security Headers

Add a security headers handler:

```crystal
class SecurityHeaders < Azu::Handler::Base
  def call(context)
    headers = context.response.headers

    # HTTPS enforcement
    headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"

    # XSS protection
    headers["X-Content-Type-Options"] = "nosniff"
    headers["X-Frame-Options"] = "DENY"
    headers["X-XSS-Protection"] = "1; mode=block"

    # CSP (customize as needed)
    headers["Content-Security-Policy"] = "default-src 'self'"

    call_next(context)
  end
end
```

## Logging Configuration

Configure production logging:

```crystal
Log.setup do |config|
  if ENV["AZU_ENV"] == "production"
    # JSON logs for production
    backend = JsonLogBackend.new(STDOUT)
    config.bind "*", :info, backend
  else
    # Human-readable for development
    config.bind "*", :debug, Log::IOBackend.new
  end
end
```

## Health Check Endpoint

Add a health check for load balancers:

```crystal
struct HealthEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Json)

  get "/health"

  def call
    checks = {
      database: check_database,
      redis: check_redis,
    }

    all_healthy = checks.values.all?

    status(all_healthy ? 200 : 503)

    json({
      status: all_healthy ? "healthy" : "unhealthy",
      checks: checks,
      timestamp: Time.utc.to_rfc3339,
      version: ENV.fetch("APP_VERSION", "unknown")
    })
  end

  private def check_database : Bool
    AcmeDB.exec("SELECT 1")
    true
  rescue
    false
  end

  private def check_redis : Bool
    Azu.cache.set("health", "ok", expires_in: 1.second)
    true
  rescue
    false
  end
end
```

## Graceful Shutdown

Handle shutdown signals:

```crystal
module MyApp
  @@running = true

  def self.start
    server = HTTP::Server.new(handlers)

    # Handle shutdown signals
    Signal::INT.trap { shutdown(server) }
    Signal::TERM.trap { shutdown(server) }

    Log.info { "Starting server on port #{port}" }
    server.listen(host, port)
  end

  private def self.shutdown(server)
    return unless @@running
    @@running = false

    Log.info { "Shutting down gracefully..." }

    # Stop accepting new connections
    server.close

    # Wait for in-flight requests
    sleep 5.seconds

    Log.info { "Shutdown complete" }
    exit 0
  end
end
```

## Connection Pooling

Configure database connection pooling:

```crystal
AcmeDB = CQL::Schema.define(:acme_db,
  adapter: CQL::Adapter::Postgres,
  uri: ENV["DATABASE_URL"],
  pool_size: ENV.fetch("DB_POOL_SIZE", "10").to_i,
  checkout_timeout: 5.seconds
)
```

## Rate Limiting

Add rate limiting for API protection:

```crystal
class RateLimiter < Azu::Handler::Base
  LIMIT = 100
  WINDOW = 1.minute

  def call(context)
    key = "ratelimit:#{client_ip(context)}"

    current = Azu.cache.increment(key)
    Azu.cache.expire(key, WINDOW) if current == 1

    context.response.headers["X-RateLimit-Limit"] = LIMIT.to_s
    context.response.headers["X-RateLimit-Remaining"] = Math.max(0, LIMIT - current).to_s

    if current > LIMIT
      context.response.status_code = 429
      context.response.print({error: "Too many requests"}.to_json)
      return
    end

    call_next(context)
  end
end
```

## Production Checklist

Before deploying:

- [ ] Environment variables set
- [ ] Database migrations run
- [ ] SSL certificate configured
- [ ] Security headers enabled
- [ ] Logging configured
- [ ] Health check endpoint added
- [ ] Rate limiting enabled
- [ ] Error monitoring set up
- [ ] Backups configured
- [ ] Metrics/monitoring in place

## See Also

- [Deploy with Docker](deploy-with-docker.md)
- [Scale Horizontally](scale-horizontally.md)

# Configure production

This guide shows you how to configure your Azu application for production deployment.

## Environment Configuration

Azu reads its settings from environment variables when the configuration is built, so a production process is
configured by its environment and not by code. The environment is selected with `CRYSTAL_ENV` (`AZU_ENV` is
ignored):

```bash
CRYSTAL_ENV=production
HOST=0.0.0.0
PORT=4000
```

| Variable | Default | Meaning |
|---|---|---|
| `CRYSTAL_ENV` | `development` | `development`, `test`, `pipeline`, `staging`, `production`, ... |
| `HOST`, `PORT` | `0.0.0.0`, `4000` | where the server listens |
| `PORT_REUSE` | `true` | `SO_REUSEPORT` on the listening socket |
| `TEMPLATE_HOT_RELOAD` | on in `development`, `test`, `pipeline` | re-read changed template files |
| `TEMPLATES_PATH` | see [templates](../templates/render-html-templates.md) | comma separated template directories |
| `SHUTDOWN_TIMEOUT` | `30` | seconds to wait for requests in flight on SIGTERM |
| `UPLOAD_MAX_FILE_SIZE` | `10485760` | bytes allowed per uploaded file and per request body |
| `SSL_CERT`, `SSL_KEY` | empty | PEM files; TLS is on when both are set |
| `CACHE_STORE`, `CACHE_REDIS_URL` | `memory`, | see [Redis cache](../caching/setup-redis-cache.md) |
| `SPARK_SECRET` | | signing secret for Spark live views, required in staging and production |
| `WEBSOCKET_ALLOWED_ORIGINS` | empty | comma separated origins allowed to open a channel |

Settings you need in code are plain properties of the configuration:

```crystal
module MyApp
  include Azu

  configure do |config|
    config.template_hot_reload = config.env.development?
    config.shutdown_timeout = 20.seconds
    config.websocket.allowed_origins = ["https://app.example.com"]
  end
end

puts MyApp.env
```

## Secrets

Keep secrets out of the image and out of source control: pass them as environment variables (`docker run -e`,
`systemd` `EnvironmentFile=`, your platform's secret store) and read them with `ENV[...]`, which raises at boot
when one is missing. Azu itself reads `SPARK_SECRET`; the application reads the rest.

An application generated with `azu new` reads `SESSION_SECRET` and `CSRF_SECRET` with `Azu::Env.secret` and refuses to
start in production without them (in development it loads them from its git-ignored `.env`). Write the same guard
yourself with [`Azu::Env.secret`](../../reference/configuration/env.md); without a key the CSRF handler generates a
random one for each process, so tokens issued by one instance are rejected by another:

```crystal
csrf = Azu::Handler::CSRF.new(secret_key: Azu::Env.secret("CSRF_SECRET"))
```

Generate a value with `openssl rand -base64 48`.

## Build for Production

Create an optimized release build:

```bash
# Build with release optimizations
crystal build --release --no-debug src/app.cr -o bin/app

# Static linking (Alpine/Docker)
crystal build --release --static --no-debug src/app.cr -o bin/app
```

`azu new my_app --docker` writes a multi-stage `Dockerfile` that does the release build and a runtime stage with
`CRYSTAL_ENV=production`, a non-root user and a `HEALTHCHECK` on `/health`. See
[Deploy with Docker](deploy-with-docker.md).

## SSL Configuration

Set `SSL_CERT` and `SSL_KEY` to the paths of a certificate and key and `start` listens with TLS
(`config.tls?`). Most deployments terminate TLS in a proxy instead and keep Azu on plain HTTP behind it.

## Security Headers

The default handler stack already includes `Azu::Handler::SecurityHeaders`
(`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`). HSTS and a content security policy are only
sent when asked for. When you pass your own handler array, list the handler yourself:

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::SecurityHeaders.new(hsts: true, content_security_policy: "default-src 'self'"),
  Azu::Handler::Static.new(fallthrough: true),
] of HTTP::Handler
```

Behind a proxy that terminates TLS, `hsts: true` is right; the headers are sent by the application on every
response.

## Logging Configuration

Requiring `azu` does not touch `Log`. Choose the backend at boot: Azu's formatter at `Debug`, or your own
level and backend. See [Add Logging](../middleware/add-logging.md) for a JSON backend.

```crystal
if Azu::CONFIG.env.production?
  Log.setup(:info, Log::IOBackend.new(formatter: Log::ShortFormat))
else
  Azu.setup_logging
end
```

## Health Check Endpoint

`Azu::Handler::HealthCheck` answers `GET /health` (and `HEAD`) before the request reaches the router: `200` with
`{"status":"ok"}` while every check passes and `503` naming the failing checks otherwise. A check that raises
counts as failing. Applications generated with `azu new` have a `/health` endpoint of their own, which the Docker
`HEALTHCHECK` calls; use the handler when you want the check to bypass the rest of the stack.

```crystal
module MyApp
  include Azu
end

database_ok = -> { true } # replace with a real probe, for example a `SELECT 1`

MyApp.start [
  Azu::Handler::HealthCheck.new(checks: {"database" => database_ok}),
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
] of HTTP::Handler
```

## Graceful Shutdown

`start` handles `SIGTERM` and `SIGINT` for you: it stops accepting connections, waits for the requests in flight
(up to `config.shutdown_timeout`, `SHUTDOWN_TIMEOUT` seconds, 30 by default), closes the Spark and PubSub
backends and returns. Do not install your own signal traps for the same purpose. Give the process manager
at least that long before it kills the process (`docker stop -t 40`, `TimeoutStopSec=40` in systemd,
`terminationGracePeriodSeconds` in Kubernetes).

```crystal
module MyApp
  include Azu

  configure do |config|
    config.shutdown_timeout = 20.seconds
  end
end
```

Streaming responses (SSE) count as in flight until the client disconnects, and WebSocket connections are not
waited for.

## Database Connections

The pool of the database connection is part of the connection URL (`DATABASE_URL`), as with any
crystal-db driver, for example `postgres://user:pass@host/db?initial_pool_size=5&max_pool_size=10`.
See the [database guides](../database/define-schema.md).

## Rate Limiting

`Azu::Handler::Throttle` counts requests per client address; it keeps its counters in the memory of
the process, so each instance of a scaled deployment counts separately:

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Throttle.new(interval: 5, duration: 900, threshold: 100, blacklist: [] of String, whitelist: [] of String),
] of HTTP::Handler
```

A client over `threshold` requests in `interval` seconds is blocked for `duration` seconds and receives `429`
with a `Retry-After` header.

## Production Checklist

Before deploying:

- [ ] `CRYSTAL_ENV=production`
- [ ] Secrets (`SPARK_SECRET`, `SESSION_SECRET`, `CSRF_SECRET`, database credentials) come from the environment
- [ ] Database migrations run
- [ ] TLS terminated by a proxy, or `SSL_CERT` and `SSL_KEY` set
- [ ] `SecurityHeaders` in the handler stack, with `hsts: true` behind TLS
- [ ] Logging configured
- [ ] `/health` answers and is wired to the load balancer
- [ ] Rate limiting where the API is public
- [ ] Shutdown grace period of the process manager is longer than `SHUTDOWN_TIMEOUT`
- [ ] Backups configured

## See Also

- [Deploy with Docker](deploy-with-docker.md)
- [Scale Horizontally](scale-horizontally.md)

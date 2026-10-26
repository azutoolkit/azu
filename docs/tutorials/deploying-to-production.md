---
description: Deploy an Azu application to a production environment.
---

# Deploying to production

This tutorial uses the `UserAPI`
from [Building a User API](building-a-user-api.md), but nothing here depends on it.

## What you'll learn

By the end of this tutorial, you'll know how to:

- Configure your app for production with environment variables
- Build an optimized release binary
- Build a Docker image
- Run it under a process manager, behind a reverse proxy
- Shut down without dropping requests

## Prerequisites

- A working Azu application
- Access to a Linux server or cloud platform
- Basic knowledge of command line and servers

## Step 1: Production configuration

Azu reads its settings from the environment, so the same binary runs in every environment. The one that matters most
is `CRYSTAL_ENV` (`AZU_ENV` is not read): `production` turns template hot reload off, shows the production error pages
and makes `SPARK_SECRET` mandatory when you use Spark.

Choose the handlers explicitly in production. An array passed to `start` is used exactly as given; the default stack
is `RequestId`, `Logger`, `Rescuer`, `SecurityHeaders` and `Static`:

```crystal
require "azu"

module UserAPI
  include Azu
end

if Azu::CONFIG.env.production?
  Log.setup(:info, Log::IOBackend.new(formatter: Log::ShortFormat))
else
  Azu.setup_logging
end

UserAPI.start [
  Azu::Handler::HealthCheck.new,
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::SecurityHeaders.new(hsts: Azu::CONFIG.env.production?),
  Azu::Handler::Static.new,
] of HTTP::Handler
```

Azu reads `PORT`, `HOST` and `SHUTDOWN_TIMEOUT` from the environment itself (Step 3 sets them), so the app does not
configure them. `Static` passes a request for something that is not a file on to the router (`fallthrough` is `true`
by default; `fallthrough: false` answers `404` itself). `HealthCheck` answers `GET /health` with `{"status":"ok"}`
before the request reaches the router. `hsts: true` sends `Strict-Transport-Security`; enable it once the site is served over HTTPS. Requiring `azu` does not set up `Log`:
you choose the level and backend, as above. See [Configure Production](../how-to/deployment/configure-production.md)
for every setting.

## Step 2: Build for production

Create a release build:

```bash
crystal build --release --no-debug src/user_api.cr -o bin/user_api
ls -lh bin/user_api
```

`--release` enables optimizations and `--no-debug` leaves out debug information.

## Step 3: Environment variables

Keep the settings in the environment of the process, not in the image or the repository. A file for systemd or
`docker run --env-file` (do not commit it):

```bash
CRYSTAL_ENV=production
HOST=0.0.0.0
PORT=4000
DATABASE_URL=postgres://user:password@db.example.com:5432/myapp_prod
CACHE_STORE=redis
CACHE_REDIS_URL=redis://redis.example.com:6379/0
SHUTDOWN_TIMEOUT=30
```

Secrets (`SPARK_SECRET`, and with an `azu new` application `SESSION_SECRET` and `CSRF_SECRET`) come from your
platform's secret store. Generate one with `openssl rand -base64 48`. A generated application refuses to start in
production without `SESSION_SECRET` and `CSRF_SECRET`, and `Azu::Spark.install` refuses to boot it without
`SPARK_SECRET`.

## Step 4: Docker deployment

An application created with `azu new my_app --docker` already has a `Dockerfile` and a `.dockerignore`. Its shape
(your Crystal version and packages differ) is a build stage and a small runtime stage:

{% code title="Dockerfile" %}
```dockerfile
FROM crystallang/crystal:1.22.1 AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-dev libssl-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY shard.yml shard.lock* ./
RUN shards install --ignore-crystal-version
COPY . .
RUN mkdir -p bin && crystal build --release --no-debug src/user_api.cr -o bin/user_api

FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libsqlite3-0 libssl3 libevent-2.1-7t64 libpcre2-8-0 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /app app
WORKDIR /app
COPY --from=build /app/bin/user_api ./user_api
COPY --from=build /app/public ./public
USER app

ENV CRYSTAL_ENV=production HOST=0.0.0.0 PORT=4000 TZ=UTC
EXPOSE 4000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/health" || exit 1
CMD ["./user_api"]
```
{% endcode %}

The secrets are deliberately not part of the image: pass them with `docker run -e` or your orchestrator. The
packages in the runtime stage depend on the libraries your binary links (`ldd bin/user_api` lists them); let `azu new
--docker` pick them for you. See [Deploy with Docker](../how-to/deployment/deploy-with-docker.md).

Build and run it:

```bash
docker build -t user_api .
docker run --rm -p 4000:4000 --env-file .env.production user_api
```

With Compose, add the database and Redis next to the app:

```yaml
services:
  app:
    build: .
    ports:
      - "4000:4000"
    env_file: .env.production
    depends_on:
      - db
      - redis
    stop_grace_period: 40s
    restart: unless-stopped

  db:
    image: postgres:16-alpine
    environment:
      - POSTGRES_DB=myapp_prod
      - POSTGRES_USER=user
      - POSTGRES_PASSWORD
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    restart: unless-stopped

volumes:
  postgres_data:
```

{% hint style="warning" %}
`stop_grace_period` is longer than `SHUTDOWN_TIMEOUT` so that Docker does not kill the process while it drains.
{% endhint %}

## Step 5: Run and stop the process

Any process manager works (systemd, Docker, your platform's runtime). What Azu needs from it:

- **The environment from Step 3.** Azu listens on `HOST:PORT`; `HOST` is `0.0.0.0` outside development.
- **The working directory.** The default `Static` handler serves `./public`, and the template path is relative to
  the working directory.
- **`SIGTERM` (or `SIGINT`) to stop.** Azu stops accepting connections, sends every open WebSocket a close frame with
  code 1001, waits up to `SHUTDOWN_TIMEOUT` seconds (30 by default) for the requests in flight, and exits. Set the
  process manager's stop timeout (`TimeoutStopSec` in systemd, `stop_grace_period` in Compose) longer than that, so it
  does not kill the process while it drains. See [Shut down gracefully](../how-to/deployment/graceful-shutdown.md).
- **A health check on `GET /health`**, answered by `HealthCheck` before the request reaches the router.
- **Migrations before the new binary starts.** Run them with the Azu CLI (`azu db:migrate`); the application binary
  does not run them.

{% hint style="warning" %}
Behind a reverse proxy that terminates TLS and forwards WebSocket upgrades, Azu sees the proxy's address as the
client address, which `Throttle` uses to count requests, unless you pass the proxy's address or network as
`trusted_proxies:` to `Throttle`: it then counts the client in `X-Forwarded-For`
([Behind a reverse proxy](../reference/handlers/built-in.md#behind-a-reverse-proxy)).
{% endhint %}

## Production checklist

Before going live:

- [ ] `CRYSTAL_ENV=production`
- [ ] Secrets in the environment, not in the image or the repository
- [ ] Database migrations run
- [ ] TLS in front of the app, and `hsts: true` once it works
- [ ] `/health` answers and is used by the load balancer or `HEALTHCHECK`
- [ ] Logging configured (`Log.setup`)
- [ ] Rate limiting where the API is public
- [ ] The stop timeout of the process manager is longer than `SHUTDOWN_TIMEOUT`

## Next steps

{% content-ref url="../how-to/deployment/configure-production.md" %}
[configure-production.md](../how-to/deployment/configure-production.md)
{% endcontent-ref %}

{% content-ref url="../reference/api/app.md" %}
[app.md](../reference/api/app.md)
{% endcontent-ref %}

{% content-ref url="../explanation/architecture/overview.md" %}
[overview.md](../explanation/architecture/overview.md)
{% endcontent-ref %}

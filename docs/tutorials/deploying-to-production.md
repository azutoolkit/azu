# Deploying to production

This tutorial teaches you how to deploy an Azu application to a production environment. It uses the `UserAPI`
from [Building a User API](building-a-user-api.md), but nothing here depends on it.

## What You'll Learn

By the end of this tutorial, you'll know how to:

- Configure your app for production with environment variables
- Build an optimized release binary
- Build a Docker image
- Run it under systemd or Docker Compose behind Nginx
- Shut down without dropping requests

## Prerequisites

- A working Azu application
- Access to a Linux server or cloud platform
- Basic knowledge of command line and servers

## Step 1: Production Configuration

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

## Step 2: Build for Production

Create a release build:

```bash
crystal build --release --no-debug src/user_api.cr -o bin/user_api
ls -lh bin/user_api
```

`--release` enables optimizations and `--no-debug` leaves out debug information.

## Step 3: Environment Variables

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
production without `SESSION_SECRET` and `CSRF_SECRET`; without `SPARK_SECRET`, Spark raises the first time it signs
or verifies a token.

## Step 4: Docker Deployment

An application created with `azu new my_app --docker` already has a `Dockerfile` and a `.dockerignore`. Its shape
(your Crystal version and packages differ) is a build stage and a small runtime stage:

```dockerfile
FROM crystallang/crystal:1.19.1 AS build
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

`stop_grace_period` is longer than `SHUTDOWN_TIMEOUT` so that Docker does not kill the process while it drains.

## Step 5: Systemd Service

For a traditional server, create `/etc/systemd/system/user-api.service`:

```ini
[Unit]
Description=User API Application
After=network.target

[Service]
Type=simple
User=appuser
Group=appuser
WorkingDirectory=/opt/user-api
ExecStart=/opt/user-api/bin/user_api
EnvironmentFile=/opt/user-api/.env
Restart=always
RestartSec=5
TimeoutStopSec=40

[Install]
WantedBy=multi-user.target
```

`WorkingDirectory` matters: the default `Static` handler serves `./public` and the template path is relative to the
working directory. Enable and start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now user-api
sudo systemctl status user-api
```

systemd stops the service with `SIGTERM`. Azu stops accepting connections, waits for the requests in flight (up to
`SHUTDOWN_TIMEOUT` seconds) and exits; `TimeoutStopSec` is longer so systemd does not kill it first.

## Step 6: Nginx Reverse Proxy

Terminate TLS in Nginx and forward to the app:

```nginx
# /etc/nginx/sites-available/user-api
server {
    listen 80;
    server_name api.example.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.example.com;

    ssl_certificate /etc/letsencrypt/live/api.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

Enable the site and get a certificate:

```bash
sudo ln -s /etc/nginx/sites-available/user-api /etc/nginx/sites-enabled/
sudo nginx -t
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d api.example.com
sudo systemctl reload nginx
```

Azu sees the proxy's address as the client address, which `Throttle` uses to count requests. Run `Throttle` only
where the peer address is the real client.

## Step 7: Deploy Script

Create `scripts/deploy.sh` on the server. Migrations are run with the Azu CLI (`azu db:migrate`), not by the
application binary:

```bash
#!/bin/bash
set -e

git pull origin main
shards install --production
crystal build --release --no-debug src/user_api.cr -o bin/user_api

azu db:migrate

sudo systemctl restart user-api

sleep 5
curl -fsS http://localhost:4000/health
```

## Step 8: CI

A pipeline that builds and tests every change, as `azu new` generates it in `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: crystallang/crystal:1.19.1
    steps:
      - uses: actions/checkout@v4
      - name: Install system dependencies
        run: |
          apt-get update
          apt-get install -y libsqlite3-dev libssl-dev
      - name: Install shards
        run: shards install --ignore-crystal-version
      - name: Check formatting
        run: crystal tool format --check src spec
      - name: Run specs
        run: crystal spec
      - name: Build
        run: crystal build --release src/user_api.cr -o bin/user_api
```

Deploying from the pipeline (SSH to the server, push an image to a registry) depends on your platform; keep its
credentials in the CI secret store.

## Production Checklist

Before going live:

- [ ] `CRYSTAL_ENV=production`
- [ ] Secrets in the environment, not in the image or the repository
- [ ] Database migrations run
- [ ] TLS in front of the app, and `hsts: true` once it works
- [ ] `/health` answers and is used by the load balancer or `HEALTHCHECK`
- [ ] Logging configured (`Log.setup`)
- [ ] Rate limiting where the API is public
- [ ] The stop timeout of the process manager is longer than `SHUTDOWN_TIMEOUT`
- [ ] Backups configured

## Key Takeaways

1. **Build optimized binaries** with `--release`
2. **Configure through the environment**, with `CRYSTAL_ENV=production`
3. **Run behind a reverse proxy** (Nginx) that terminates TLS
4. **Expose `/health`** for the load balancer
5. **Give the process time to drain**: `SIGTERM` waits for requests in flight
6. **Keep secrets out of the image**

## Next Steps

Congratulations! You've completed the Azu tutorial series. Explore further:

- [How-to Guides](../how-to/deployment/configure-production.md) - Task-specific solutions
- [API Reference](../reference/api/app.md) - Complete API documentation
- [Architecture](../explanation/architecture/overview.md) - Deep dive into Azu internals

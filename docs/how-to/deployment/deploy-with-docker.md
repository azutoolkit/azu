---
description: Containerize your Azu application and run it with Docker.
---

# Deploy with Docker

{% hint style="info" %}
A project generated with `azu new --docker` by the [azu CLI](https://github.com/azutoolkit/azu_cli) already has a
multi-stage `Dockerfile` and a `.dockerignore`.
{% endhint %}

{% stepper %}
{% step %}
#### Basic Dockerfile

Create a multi-stage Dockerfile:

{% code title="Dockerfile" %}
```dockerfile
# Build stage
FROM crystallang/crystal:1.19.1-alpine AS builder

WORKDIR /app

# Copy dependency files
COPY shard.yml shard.lock ./

# Install dependencies
RUN shards install --production

# Copy source code
COPY src/ src/

# Build release binary
RUN crystal build --release --static --no-debug src/app.cr -o bin/app

# Runtime stage
FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/bin/app .

# Static files and templates (the app sets config.templates.path = "./public/templates")
COPY public/ public/

# Create non-root user
RUN adduser -D -u 1000 appuser
USER appuser

EXPOSE 8080

# Production binds 0.0.0.0 unless HOST says otherwise
ENV CRYSTAL_ENV=production
ENV PORT=8080

CMD ["./app"]
```
{% endcode %}
{% endstep %}

{% step %}
#### .dockerignore

Create a `.dockerignore` file:

{% code title=".dockerignore" %}
```
.git
.github
*.md
docs/
spec/
tmp/
log/
.env*
!.env.example
bin/
lib/
.crystal/
```
{% endcode %}
{% endstep %}

{% step %}
#### Build and run

```bash
# Build the image
docker build -t myapp:latest .

# Run the container
docker run -p 8080:8080 \
  -e DATABASE_URL=postgres://... \
  -e CACHE_STORE=redis \
  -e CACHE_REDIS_URL=redis://... \
  myapp:latest

# Run with env file
docker run -p 8080:8080 --env-file .env.production myapp:latest
```

The cache reads `CACHE_STORE` and `CACHE_REDIS_URL`, not `REDIS_URL`; see
[Set up a Redis cache](../caching/setup-redis-cache.md).

{% hint style="warning" %}
Development binds `127.0.0.1` by default, which is unreachable from outside the container: set `HOST=0.0.0.0` when
you run with `CRYSTAL_ENV=development`.
{% endhint %}
{% endstep %}

{% step %}
#### Health checks

Add health check to Dockerfile:

{% code title="Dockerfile" %}
```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD wget -q --spider http://localhost:8080/health || exit 1
```
{% endcode %}
{% endstep %}
{% endstepper %}

## See also

- [Configure Production](configure-production.md)
- [Scale Horizontally](scale-horizontally.md)

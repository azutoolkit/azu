# Deploying to Production

This tutorial teaches you how to deploy your Azu application to a production environment.

## What You'll Learn

By the end of this tutorial, you'll know how to:

- Configure your app for production
- Build an optimized release binary
- Set up a production server
- Deploy with Docker
- Configure SSL and security

## Prerequisites

- A working Azu application
- Access to a Linux server or cloud platform
- Basic knowledge of command line and servers

## Step 1: Production Configuration

Create production settings in your application:

```crystal
module UserAPI
  include Azu

  configure do
    # Use environment variables for all settings
    port = ENV.fetch("PORT", "8080").to_i
    host = ENV.fetch("HOST", "0.0.0.0")

    # Production settings
    if ENV["AZU_ENV"]? == "production"
      log.level = Log::Severity::INFO

      # SSL configuration
      ssl_cert = ENV["SSL_CERT"]?
      ssl_key = ENV["SSL_KEY"]?
    else
      log.level = Log::Severity::DEBUG
    end
  end
end
```

## Step 2: Build for Production

Create a release build:

```bash
# Build optimized binary
crystal build --release --no-debug src/user_api.cr -o bin/user_api

# Check binary size
ls -lh bin/user_api
```

The `--release` flag enables optimizations and `--no-debug` removes debug symbols for a smaller binary.

## Step 3: Environment Variables

Create a `.env.production` file (don't commit this):

```bash
AZU_ENV=production
PORT=8080
HOST=0.0.0.0
DATABASE_URL=postgres://user:password@db.example.com:5432/myapp_prod
REDIS_URL=redis://redis.example.com:6379/0
SECRET_KEY=your-secure-secret-key-here
```

## Step 4: Docker Deployment

Create a `Dockerfile`:

```dockerfile
# Build stage
FROM crystallang/crystal:1.17.1-alpine AS builder

WORKDIR /app

# Copy dependency files
COPY shard.yml shard.lock ./

# Install dependencies
RUN shards install --production

# Copy source code
COPY src/ src/

# Build release binary
RUN crystal build --release --static --no-debug src/user_api.cr -o bin/user_api

# Runtime stage
FROM alpine:latest

RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/bin/user_api .

# Copy static files if any
COPY public/ public/

# Create non-root user
RUN adduser -D appuser
USER appuser

EXPOSE 8080

CMD ["./user_api"]
```

Create `docker-compose.yml`:

```yaml
version: "3.8"

services:
  app:
    build: .
    ports:
      - "8080:8080"
    environment:
      - AZU_ENV=production
      - PORT=8080
      - DATABASE_URL=postgres://user:password@db:5432/myapp_prod
      - REDIS_URL=redis://redis:6379/0
    depends_on:
      - db
      - redis
    restart: unless-stopped

  db:
    image: postgres:15-alpine
    environment:
      - POSTGRES_DB=myapp_prod
      - POSTGRES_USER=user
      - POSTGRES_PASSWORD=password
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data
    restart: unless-stopped

volumes:
  postgres_data:
  redis_data:
```

Build and run:

```bash
docker-compose build
docker-compose up -d
```

## Step 5: Systemd Service

For traditional server deployment, create `/etc/systemd/system/user-api.service`:

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
Restart=always
RestartSec=5
Environment=AZU_ENV=production
Environment=PORT=8080
EnvironmentFile=/opt/user-api/.env

[Install]
WantedBy=multi-user.target
```

Enable and start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable user-api
sudo systemctl start user-api
sudo systemctl status user-api
```

## Step 6: Nginx Reverse Proxy

Configure Nginx as a reverse proxy with SSL:

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
        proxy_pass http://127.0.0.1:8080;
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

Enable the site:

```bash
sudo ln -s /etc/nginx/sites-available/user-api /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

## Step 7: SSL with Let's Encrypt

Install and configure Certbot:

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d api.example.com
```

## Step 8: Health Check Endpoint

Add a health check endpoint:

```crystal
struct HealthEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Json)

  get "/health"

  def call
    json({
      status: "healthy",
      timestamp: Time.utc.to_rfc3339,
      version: "1.0.0"
    })
  end
end
```

## Step 9: Deployment Script

Create `scripts/deploy.sh`:

```bash
#!/bin/bash
set -e

echo "Starting deployment..."

# Pull latest code
git pull origin main

# Install dependencies
shards install --production

# Build application
crystal build --release --no-debug src/user_api.cr -o bin/user_api

# Run database migrations
./bin/user_api --migrate

# Restart service
sudo systemctl restart user-api

# Verify health
sleep 5
curl -f http://localhost:8080/health || exit 1

echo "Deployment completed successfully!"
```

## Step 10: CI/CD with GitHub Actions

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Crystal
        uses: crystal-lang/install-crystal@v1
        with:
          crystal: 1.17.1

      - name: Install dependencies
        run: shards install

      - name: Run tests
        run: crystal spec

  deploy:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to server
        uses: appleboy/ssh-action@v1.0.0
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SERVER_SSH_KEY }}
          script: |
            cd /opt/user-api
            ./scripts/deploy.sh
```

## Production Checklist

Before going live:

- [ ] Environment variables configured
- [ ] Database migrations run
- [ ] SSL certificate installed
- [ ] Health check endpoint working
- [ ] Logging configured
- [ ] Error monitoring set up
- [ ] Backups configured
- [ ] Rate limiting enabled
- [ ] Security headers added
- [ ] Performance tested

## Monitoring

Add a simple monitoring endpoint:

```crystal
struct MetricsEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Json)

  get "/metrics"

  def call
    json({
      uptime: Process.times.real.to_i,
      memory_mb: GC.stats.heap_size / (1024 * 1024),
      requests_total: RequestCounter.total
    })
  end
end
```

## Security Headers

Add security middleware:

```crystal
class SecurityHeaders < Azu::Handler::Base
  def call(context)
    response = context.response
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"

    call_next(context)
  end
end
```

## Key Takeaways

1. **Build optimized binaries** with `--release`
2. **Use environment variables** for configuration
3. **Run behind a reverse proxy** (Nginx) for SSL
4. **Set up health checks** for monitoring
5. **Automate deployments** with CI/CD
6. **Enable security headers** and HTTPS

## Next Steps

Congratulations! You've completed the Azu tutorial series. Explore further:

- [How-to Guides](../how-to/) - Task-specific solutions
- [API Reference](../reference/) - Complete API documentation
- [Architecture](../explanation/architecture/) - Deep dive into Azu internals

---

**Your application is production-ready!** You now have a fully deployed, secure Azu application.

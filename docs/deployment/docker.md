# Docker Deployment

This guide covers containerizing Azu applications with Docker for development, testing, and production deployments.

## Dockerfile

### Basic Dockerfile

```dockerfile
# Dockerfile
FROM crystallang/crystal:1.15.1-alpine AS builder

# Install system dependencies
RUN apk add --no-cache \
    build-base \
    git \
    libffi-dev \
    openssl-dev \
    sqlite-dev \
    postgresql-dev \
    mysql-dev

# Set working directory
WORKDIR /app

# Copy dependency files
COPY shard.yml shard.lock ./

# Install dependencies
RUN shards install --production

# Copy source code
COPY src/ ./src/
COPY lib/ ./lib/

# Build application
RUN crystal build --release src/azu-app.cr -o /app/bin/azu-app

# Production stage
FROM alpine:3.18

# Install runtime dependencies
RUN apk add --no-cache \
    libc6-compat \
    libffi \
    openssl \
    sqlite \
    postgresql-client \
    mysql-client

# Create app user
RUN addgroup -g 1000 -S azu && \
    adduser -u 1000 -S azu -G azu

# Set working directory
WORKDIR /app

# Copy binary from builder stage
COPY --from=builder /app/bin/azu-app /app/bin/azu-app

# Copy static files
COPY public/ ./public/

# Change ownership
RUN chown -R azu:azu /app

# Switch to non-root user
USER azu

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1

# Start application
CMD ["/app/bin/azu-app"]
```

### Multi-stage Dockerfile

```dockerfile
# Multi-stage Dockerfile for optimized production builds
FROM crystallang/crystal:1.15.1-alpine AS base

# Install system dependencies
RUN apk add --no-cache \
    build-base \
    git \
    libffi-dev \
    openssl-dev \
    sqlite-dev \
    postgresql-dev \
    mysql-dev

WORKDIR /app

# Dependencies stage
FROM base AS dependencies
COPY shard.yml shard.lock ./
RUN shards install --production

# Build stage
FROM dependencies AS builder
COPY src/ ./src/
COPY lib/ ./lib/
RUN crystal build --release src/azu-app.cr -o /app/bin/azu-app

# Production stage
FROM alpine:3.18 AS production

# Install runtime dependencies
RUN apk add --no-cache \
    libc6-compat \
    libffi \
    openssl \
    sqlite \
    postgresql-client \
    mysql-client

# Create app user
RUN addgroup -g 1000 -S azu && \
    adduser -u 1000 -S azu -G azu

WORKDIR /app

# Copy binary and static files
COPY --from=builder /app/bin/azu-app /app/bin/azu-app
COPY --from=builder /app/public/ ./public/

# Change ownership
RUN chown -R azu:azu /app

# Switch to non-root user
USER azu

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1

# Start application
CMD ["/app/bin/azu-app"]
```

## Docker Compose

### Development Environment

```yaml
# docker-compose.yml
version: "3.8"

services:
  app:
    build: .
    ports:
      - "3000:3000"
    environment:
      - AZU_ENVIRONMENT=development
      - DATABASE_URL=postgresql://postgres:password@db:5432/azu_dev
      - REDIS_URL=redis://redis:6379/0
    volumes:
      - .:/app
      - /app/lib
    depends_on:
      - db
      - redis
    restart: unless-stopped

  db:
    image: postgres:15
    environment:
      - POSTGRES_DB=azu_dev
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=password
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data
    ports:
      - "6379:6379"
    restart: unless-stopped

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
    depends_on:
      - app
    restart: unless-stopped

volumes:
  postgres_data:
  redis_data:
```

### Production Environment

```yaml
# docker-compose.prod.yml
version: "3.8"

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.prod
    ports:
      - "3000:3000"
    environment:
      - AZU_ENVIRONMENT=production
      - DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/azu_prod
      - REDIS_URL=redis://redis:6379/0
      - SECRET_KEY=${SECRET_KEY}
    depends_on:
      - db
      - redis
    restart: unless-stopped
    deploy:
      replicas: 3
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M

  db:
    image: postgres:15
    environment:
      - POSTGRES_DB=azu_prod
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 512M

  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 256M
        reservations:
          memory: 128M

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
      - ./ssl:/etc/ssl
    depends_on:
      - app
    restart: unless-stopped

volumes:
  postgres_data:
  redis_data:
```

## Docker Compose Overrides

### Development Override

```yaml
# docker-compose.override.yml
version: "3.8"

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.dev
    volumes:
      - .:/app
      - /app/lib
    environment:
      - AZU_DEBUG=true
      - AZU_LOG_LEVEL=debug
    command: crystal run src/azu-app.cr

  db:
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_DB=azu_dev

  redis:
    ports:
      - "6379:6379"
```

### Testing Override

```yaml
# docker-compose.test.yml
version: "3.8"

services:
  app:
    build: .
    environment:
      - AZU_ENVIRONMENT=test
      - DATABASE_URL=postgresql://postgres:password@db:5432/azu_test
      - REDIS_URL=redis://redis:6379/1
    command: crystal spec

  db:
    image: postgres:15
    environment:
      - POSTGRES_DB=azu_test
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=password
    volumes:
      - postgres_test_data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    volumes:
      - redis_test_data:/data

volumes:
  postgres_test_data:
  redis_test_data:
```

## Nginx Configuration

### Development Nginx

```nginx
# nginx.conf
events {
    worker_connections 1024;
}

http {
    upstream app {
        server app:3000;
    }

    server {
        listen 80;
        server_name localhost;

        location / {
            proxy_pass http://app;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # WebSocket support
        location /ws {
            proxy_pass http://app;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
```

### Production Nginx

```nginx
# nginx.conf
events {
    worker_connections 1024;
}

http {
    upstream app {
        server app:3000;
    }

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

    server {
        listen 80;
        server_name your-domain.com;
        return 301 https://$server_name$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name your-domain.com;

        ssl_certificate /etc/ssl/certs/app.crt;
        ssl_certificate_key /etc/ssl/private/app.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256;

        # Security headers
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options DENY always;
        add_header X-XSS-Protection "1; mode=block" always;

        # Rate limiting
        limit_req zone=api burst=20 nodelay;

        location / {
            proxy_pass http://app;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Timeouts
            proxy_connect_timeout 30s;
            proxy_send_timeout 30s;
            proxy_read_timeout 30s;
        }

        # WebSocket support
        location /ws {
            proxy_pass http://app;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Static files
        location /static {
            alias /var/www/azu-app/public;
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }
}
```

## Environment Configuration

### Environment Files

```bash
# .env.development
AZU_ENVIRONMENT=development
AZU_DEBUG=true
AZU_LOG_LEVEL=debug
DATABASE_URL=postgresql://postgres:password@db:5432/azu_dev
REDIS_URL=redis://redis:6379/0
```

```bash
# .env.production
AZU_ENVIRONMENT=production
AZU_DEBUG=false
AZU_LOG_LEVEL=info
DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/azu_prod
REDIS_URL=redis://redis:6379/0
SECRET_KEY=${SECRET_KEY}
```

### Docker Secrets

```yaml
# docker-compose.secrets.yml
version: "3.8"

services:
  app:
    environment:
      - DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/azu_prod
      - SECRET_KEY=${SECRET_KEY}
    secrets:
      - db_password
      - secret_key

  db:
    environment:
      - POSTGRES_PASSWORD_FILE=/run/secrets/db_password
    secrets:
      - db_password

secrets:
  db_password:
    file: ./secrets/db_password.txt
  secret_key:
    file: ./secrets/secret_key.txt
```

## Health Checks

### Application Health Check

```crystal
# src/health.cr
struct HealthEndpoint
  include Azu::Endpoint

  get "/health"

  def call
    health_status = {
      "status" => "healthy",
      "timestamp" => Time.utc.to_s,
      "version" => Azu::VERSION,
      "database" => check_database,
      "redis" => check_redis,
      "memory" => check_memory
    }

    response.header("Content-Type", "application/json")
    response.body(health_status.to_json)
  end

  private def check_database
    # Database health check
    true
  end

  private def check_redis
    # Redis health check
    true
  end

  private def check_memory
    # Memory usage check
    System.memory_usage
  end
end
```

### Docker Health Check

```dockerfile
# Health check in Dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1
```

## Monitoring and Logging

### Log Configuration

```crystal
# Production logging configuration
Azu::Logger.configure do |config|
  config.level = :info
  config.format = :json
  config.output = STDOUT
end
```

### Docker Logging

```yaml
# docker-compose.logging.yml
version: "3.8"

services:
  app:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  db:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  redis:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

## Scaling

### Horizontal Scaling

```yaml
# docker-compose.scale.yml
version: "3.8"

services:
  app:
    deploy:
      replicas: 3
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
```

### Load Balancing

```nginx
# nginx load balancing
upstream app {
    server app_1:3000;
    server app_2:3000;
    server app_3:3000;
}
```

## Security

### Security Scanning

```dockerfile
# Security scanning in Dockerfile
FROM crystallang/crystal:1.15.1-alpine AS security-scan

# Install security tools
RUN apk add --no-cache \
    git \
    curl \
    jq

# Run security scan
RUN curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
RUN trivy fs --exit-code 1 --severity HIGH,CRITICAL .
```

### Non-root User

```dockerfile
# Create non-root user
RUN addgroup -g 1000 -S azu && \
    adduser -u 1000 -S azu -G azu

# Change ownership
RUN chown -R azu:azu /app

# Switch to non-root user
USER azu
```

## Development Workflow

### Development Commands

```bash
# Start development environment
docker-compose up -d

# Run tests
docker-compose -f docker-compose.test.yml run app

# Build production image
docker build -t azu-app:latest .

# Run production container
docker run -d -p 3000:3000 azu-app:latest
```

### Debugging

```bash
# Debug running container
docker exec -it azu-app-container sh

# View logs
docker-compose logs -f app

# Restart services
docker-compose restart app
```

## Next Steps

- Learn about [Production Deployment](production.md)
- Explore [Scaling Strategies](scaling.md)
- Understand [Monitoring and Alerting](monitoring.md)
- See [Security Best Practices](security.md)

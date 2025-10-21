# Production Deployment

This guide covers deploying Azu applications to production environments with proper configuration, monitoring, and security considerations.

## Deployment Architecture

```mermaid
graph TB
    Client[Client] --> LB[Load Balancer]
    LB --> App1[App Instance 1]
    LB --> App2[App Instance 2]
    LB --> App3[App Instance 3]

    App1 --> DB[(Database)]
    App2 --> DB
    App3 --> DB

    App1 --> Cache[(Redis Cache)]
    App2 --> Cache
    App3 --> Cache

    App1 --> Files[(File Storage)]
    App2 --> Files
    App3 --> Files

    Monitor[Monitoring] --> App1
    Monitor --> App2
    Monitor --> App3

    style Client fill:#e1f5fe
    style LB fill:#fff3e0
    style DB fill:#e8f5e8
    style Cache fill:#fce4ec
    style Monitor fill:#f3e5f5
```

## Production Checklist

### Pre-deployment

- [ ] Environment variables configured
- [ ] Database migrations completed
- [ ] SSL certificates installed
- [ ] Security headers configured
- [ ] Monitoring and logging setup
- [ ] Backup strategy implemented
- [ ] Performance testing completed

### Security Configuration

```crystal
# Production security settings
Azu.configure do |config|
  config.debug = false
  config.ssl = true
  config.ssl_cert = "/etc/ssl/certs/app.crt"
  config.ssl_key = "/etc/ssl/private/app.key"

  # Security headers
  config.security_headers = {
    "Strict-Transport-Security" => "max-age=31536000; includeSubDomains",
    "X-Content-Type-Options" => "nosniff",
    "X-Frame-Options" => "DENY",
    "X-XSS-Protection" => "1; mode=block"
  }
end
```

### Environment Variables

```bash
# Production environment variables
export AZU_ENVIRONMENT=production
export AZU_PORT=443
export AZU_HOST=0.0.0.0
export AZU_DEBUG=false
export AZU_SSL=true
export AZU_SSL_CERT=/etc/ssl/certs/app.crt
export AZU_SSL_KEY=/etc/ssl/private/app.key
export DATABASE_URL=postgresql://user:pass@localhost:5432/app_prod
export REDIS_URL=redis://localhost:6379/0
export SECRET_KEY=your-production-secret-key
```

## Server Configuration

### Nginx Reverse Proxy

```nginx
# /etc/nginx/sites-available/azu-app
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

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Static files
    location /static {
        alias /var/www/azu-app/public;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
```

### Apache Virtual Host

```apache
# /etc/apache2/sites-available/azu-app.conf
<VirtualHost *:80>
    ServerName your-domain.com
    Redirect permanent / https://your-domain.com/
</VirtualHost>

<VirtualHost *:443>
    ServerName your-domain.com
    DocumentRoot /var/www/azu-app/public

    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/app.crt
    SSLCertificateKeyFile /etc/ssl/private/app.key

    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:3000/
    ProxyPassReverse / http://127.0.0.1:3000/

    # WebSocket support
    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} websocket [NC]
    RewriteCond %{HTTP:Connection} upgrade [NC]
    RewriteRule ^/?(.*) "ws://127.0.0.1:3000/$1" [P,L]
</VirtualHost>
```

## Process Management

### Systemd Service

```ini
# /etc/systemd/system/azu-app.service
[Unit]
Description=Azu Web Application
After=network.target

[Service]
Type=simple
User=azu
Group=azu
WorkingDirectory=/var/www/azu-app
ExecStart=/usr/local/bin/azu-app
Restart=always
RestartSec=5
Environment=AZU_ENVIRONMENT=production
Environment=DATABASE_URL=postgresql://user:pass@localhost:5432/app_prod
Environment=REDIS_URL=redis://localhost:6379/0

[Install]
WantedBy=multi-user.target
```

### PM2 Process Manager

```javascript
// ecosystem.config.js
module.exports = {
  apps: [
    {
      name: "azu-app",
      script: "./bin/azu-app",
      instances: "max",
      exec_mode: "cluster",
      env: {
        NODE_ENV: "production",
        AZU_ENVIRONMENT: "production",
        PORT: 3000,
      },
      error_file: "./logs/err.log",
      out_file: "./logs/out.log",
      log_file: "./logs/combined.log",
      time: true,
    },
  ],
};
```

### Docker Compose

```yaml
# docker-compose.prod.yml
version: "3.8"

services:
  app:
    build: .
    ports:
      - "3000:3000"
    environment:
      - AZU_ENVIRONMENT=production
      - DATABASE_URL=postgresql://user:pass@db:5432/app_prod
      - REDIS_URL=redis://redis:6379/0
    depends_on:
      - db
      - redis
    restart: unless-stopped

  db:
    image: postgres:15
    environment:
      - POSTGRES_DB=app_prod
      - POSTGRES_USER=user
      - POSTGRES_PASSWORD=pass
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data
    restart: unless-stopped

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

## Database Setup

### PostgreSQL Configuration

```sql
-- Create production database
CREATE DATABASE app_prod;
CREATE USER app_user WITH PASSWORD 'secure_password';
GRANT ALL PRIVILEGES ON DATABASE app_prod TO app_user;

-- Create read replica user
CREATE USER app_readonly WITH PASSWORD 'readonly_password';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;
```

### Database Migrations

```crystal
# Run migrations in production
Azu::Database.migrate

# Or with specific version
Azu::Database.migrate_to_version(20231201000000)
```

### Database Backup

```bash
# Automated backup script
#!/bin/bash
BACKUP_DIR="/var/backups/azu-app"
DATE=$(date +%Y%m%d_%H%M%S)
pg_dump app_prod > "$BACKUP_DIR/backup_$DATE.sql"
gzip "$BACKUP_DIR/backup_$DATE.sql"

# Keep only last 30 days
find $BACKUP_DIR -name "backup_*.sql.gz" -mtime +30 -delete
```

## Monitoring and Logging

### Application Monitoring

```crystal
# Production monitoring configuration
Azu.configure do |config|
  config.monitoring_enabled = true
  config.metrics_port = 9090
  config.health_check_path = "/health"

  # Logging
  config.log_level = :info
  config.log_format = :json
  config.log_file = "/var/log/azu-app/app.log"
end
```

### Health Check Endpoint

```crystal
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

### Log Aggregation

```crystal
# Structured logging for production
Azu::Logger.configure do |config|
  config.level = :info
  config.format = :json
  config.output = STDOUT
end

# Custom log formatter
class ProductionLogger < Azu::Logger
  def format(level, message, context)
    {
      timestamp: Time.utc.to_s,
      level: level.to_s,
      message: message,
      context: context,
      service: "azu-app",
      version: Azu::VERSION
    }.to_json
  end
end
```

## Performance Optimization

### Caching Strategy

```crystal
# Production caching configuration
Azu.configure do |config|
  config.cache_type = :redis
  config.cache_ttl = 1.hour
  config.cache_compression = true

  # Cache warming
  config.cache_warmup = true
  config.cache_warmup_paths = ["/api/users", "/api/posts"]
end
```

### Database Optimization

```crystal
# Database connection pooling
Azu.configure do |config|
  config.database_pool_size = 20
  config.database_pool_timeout = 5.seconds
  config.database_statement_timeout = 30.seconds
end
```

### Static File Serving

```crystal
# Static file optimization
Azu.configure do |config|
  config.static_cache_ttl = 1.year
  config.static_compression = true
  config.static_etag = true
end
```

## Security Hardening

### SSL/TLS Configuration

```crystal
# SSL configuration
Azu.configure do |config|
  config.ssl = true
  config.ssl_cert = "/etc/ssl/certs/app.crt"
  config.ssl_key = "/etc/ssl/private/app.key"
  config.ssl_protocols = ["TLSv1.2", "TLSv1.3"]
  config.ssl_ciphers = "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256"
end
```

### Security Headers

```crystal
# Security headers middleware
class SecurityHeaders < Azu::Handler::Base
  def call(request, response)
    response.header("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
    response.header("X-Content-Type-Options", "nosniff")
    response.header("X-Frame-Options", "DENY")
    response.header("X-XSS-Protection", "1; mode=block")
    response.header("Referrer-Policy", "strict-origin-when-cross-origin")
    response.header("Content-Security-Policy", "default-src 'self'")

    yield
  end
end
```

### Rate Limiting

```crystal
# Production rate limiting
Azu.configure do |config|
  config.rate_limit_requests = 1000
  config.rate_limit_window = 1.minute
  config.rate_limit_storage = :redis
  config.rate_limit_skip_successful = true
end
```

## Backup and Recovery

### Database Backup

```bash
# Automated database backup
#!/bin/bash
BACKUP_DIR="/var/backups/azu-app"
DATE=$(date +%Y%m%d_%H%M%S)

# Create backup
pg_dump app_prod | gzip > "$BACKUP_DIR/db_backup_$DATE.sql.gz"

# Upload to cloud storage
aws s3 cp "$BACKUP_DIR/db_backup_$DATE.sql.gz" s3://azu-app-backups/

# Cleanup old backups
find $BACKUP_DIR -name "db_backup_*.sql.gz" -mtime +7 -delete
```

### Application Backup

```bash
# Application files backup
#!/bin/bash
BACKUP_DIR="/var/backups/azu-app"
APP_DIR="/var/www/azu-app"
DATE=$(date +%Y%m%d_%H%M%S)

# Create application backup
tar -czf "$BACKUP_DIR/app_backup_$DATE.tar.gz" -C $APP_DIR .

# Upload to cloud storage
aws s3 cp "$BACKUP_DIR/app_backup_$DATE.tar.gz" s3://azu-app-backups/
```

## Deployment Automation

### CI/CD Pipeline

```yaml
# .github/workflows/deploy.yml
name: Deploy to Production

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Crystal
        uses: oprypin/crystal-setup-action@v1
        with:
          crystal-version: "1.15.1"

      - name: Install dependencies
        run: shards install

      - name: Run tests
        run: crystal spec

      - name: Build application
        run: crystal build --release src/azu-app.cr

      - name: Deploy to production
        run: |
          # Deploy script
          ./scripts/deploy.sh
```

### Deployment Script

```bash
#!/bin/bash
# scripts/deploy.sh

set -e

echo "Starting deployment..."

# Pull latest code
git pull origin main

# Install dependencies
shards install

# Run migrations
crystal run src/migrate.cr

# Build application
crystal build --release src/azu-app.cr

# Restart services
sudo systemctl restart azu-app
sudo systemctl reload nginx

echo "Deployment completed successfully!"
```

## Troubleshooting

### Common Issues

1. **Port already in use**

   ```bash
   sudo lsof -i :3000
   sudo kill -9 <PID>
   ```

2. **Database connection issues**

   ```bash
   # Check database status
   sudo systemctl status postgresql

   # Check connection
   psql -h localhost -U app_user -d app_prod
   ```

3. **SSL certificate issues**

   ```bash
   # Check certificate validity
   openssl x509 -in /etc/ssl/certs/app.crt -text -noout

   # Test SSL connection
   openssl s_client -connect your-domain.com:443
   ```

### Performance Issues

1. **High CPU usage**

   - Check for infinite loops
   - Monitor database queries
   - Review caching strategy

2. **Memory leaks**

   - Monitor memory usage
   - Check for unclosed connections
   - Review object lifecycle

3. **Slow response times**
   - Enable query logging
   - Check database indexes
   - Review caching configuration

## Next Steps

- Learn about [Docker Deployment](docker.md)
- Explore [Scaling Strategies](scaling.md)
- Understand [Monitoring and Alerting](monitoring.md)
- See [Security Best Practices](security.md)

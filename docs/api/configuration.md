# Configuration API

Azu provides a comprehensive configuration system for managing application settings, environment-specific values, and runtime behavior.

## Azu::Configuration

The main configuration class for Azu applications.

### Properties

#### `port : Int32`

Server port number (default: 3000).

```crystal
Azu.configure do |config|
  config.port = 8080
end
```

#### `host : String`

Server host address (default: "0.0.0.0").

```crystal
Azu.configure do |config|
  config.host = "localhost"
end
```

#### `environment : String`

Application environment (default: "development").

```crystal
Azu.configure do |config|
  config.environment = "production"
end
```

#### `debug : Bool`

Enable debug mode (default: false).

```crystal
Azu.configure do |config|
  config.debug = true
end
```

#### `ssl : Bool`

Enable SSL/TLS (default: false).

```crystal
Azu.configure do |config|
  config.ssl = true
end
```

#### `ssl_cert : String?`

Path to SSL certificate file.

```crystal
Azu.configure do |config|
  config.ssl_cert = "/path/to/cert.pem"
end
```

#### `ssl_key : String?`

Path to SSL private key file.

```crystal
Azu.configure do |config|
  config.ssl_key = "/path/to/key.pem"
end
```

## Environment Configuration

### Development Environment

```crystal
if Azu::Environment.development?
  Azu.configure do |config|
    config.debug = true
    config.port = 3000
  end
end
```

### Production Environment

```crystal
if Azu::Environment.production?
  Azu.configure do |config|
    config.debug = false
    config.port = 80
    config.ssl = true
  end
end
```

### Environment Variables

```crystal
Azu.configure do |config|
  config.port = ENV["PORT"]?.try(&.to_i) || 3000
  config.host = ENV["HOST"]? || "0.0.0.0"
  config.environment = ENV["ENVIRONMENT"]? || "development"
  config.debug = ENV["DEBUG"]? == "true"
end
```

## Database Configuration

### Database URL

```crystal
Azu.configure do |config|
  config.database_url = ENV["DATABASE_URL"]? || "sqlite3://./app.db"
end
```

### Connection Pool

```crystal
Azu.configure do |config|
  config.database_pool_size = 10
  config.database_pool_timeout = 5.seconds
end
```

## Cache Configuration

### Redis Configuration

```crystal
Azu.configure do |config|
  config.redis_url = ENV["REDIS_URL"]? || "redis://localhost:6379"
  config.redis_pool_size = 5
end
```

### Memory Cache

```crystal
Azu.configure do |config|
  config.cache_type = :memory
  config.cache_size = 1000
  config.cache_ttl = 1.hour
end
```

## Logging Configuration

### Log Level

```crystal
Azu.configure do |config|
  config.log_level = :info
end
```

### Log Format

```crystal
Azu.configure do |config|
  config.log_format = :json
end
```

### Log File

```crystal
Azu.configure do |config|
  config.log_file = "/var/log/azu/app.log"
end
```

## Security Configuration

### CORS Settings

```crystal
Azu.configure do |config|
  config.cors_origins = ["http://localhost:3000", "https://example.com"]
  config.cors_methods = ["GET", "POST", "PUT", "DELETE"]
  config.cors_headers = ["Content-Type", "Authorization"]
  config.cors_credentials = true
end
```

### CSRF Protection

```crystal
Azu.configure do |config|
  config.csrf_secret = ENV["CSRF_SECRET"]? || "your-secret-key"
  config.csrf_token_header = "X-CSRF-Token"
end
```

### Rate Limiting

```crystal
Azu.configure do |config|
  config.rate_limit_requests = 100
  config.rate_limit_window = 1.minute
  config.rate_limit_storage = :memory
end
```

## Template Configuration

### Template Directory

```crystal
Azu.configure do |config|
  config.template_directory = "src/templates"
end
```

### Template Engine

```crystal
Azu.configure do |config|
  config.template_engine = :jinja2
end
```

### Hot Reload

```crystal
Azu.configure do |config|
  config.template_hot_reload = Azu::Environment.development?
end
```

## WebSocket Configuration

### WebSocket Settings

```crystal
Azu.configure do |config|
  config.websocket_timeout = 30.seconds
  config.websocket_max_connections = 1000
end
```

### Channel Configuration

```crystal
Azu.configure do |config|
  config.channel_prefix = "/ws"
  config.channel_authentication = true
end
```

## Performance Configuration

### Worker Threads

```crystal
Azu.configure do |config|
  config.worker_threads = 4
end
```

### Request Timeout

```crystal
Azu.configure do |config|
  config.request_timeout = 30.seconds
end
```

### Response Compression

```crystal
Azu.configure do |config|
  config.compression = true
  config.compression_level = 6
end
```

## Monitoring Configuration

### Metrics

```crystal
Azu.configure do |config|
  config.metrics_enabled = true
  config.metrics_port = 9090
end
```

### Health Checks

```crystal
Azu.configure do |config|
  config.health_check_path = "/health"
  config.health_check_interval = 10.seconds
end
```

## Configuration Files

### YAML Configuration

```yaml
# config/development.yml
port: 3000
host: localhost
debug: true
database_url: sqlite3://./app.db
```

```crystal
# Load YAML configuration
config = YAML.parse(File.read("config/development.yml"))
Azu.configure do |c|
  c.port = config["port"].as_i
  c.host = config["host"].as_s
  c.debug = config["debug"].as_bool
  c.database_url = config["database_url"].as_s
end
```

### JSON Configuration

```json
{
  "port": 3000,
  "host": "localhost",
  "debug": true,
  "database_url": "sqlite3://./app.db"
}
```

```crystal
# Load JSON configuration
config = JSON.parse(File.read("config/development.json"))
Azu.configure do |c|
  c.port = config["port"].as_i
  c.host = config["host"].as_s
  c.debug = config["debug"].as_bool
  c.database_url = config["database_url"].as_s
end
```

## Configuration Validation

### Required Settings

```crystal
Azu.configure do |config|
  config.port = ENV["PORT"]?.try(&.to_i) || raise "PORT environment variable is required"
  config.database_url = ENV["DATABASE_URL"]? || raise "DATABASE_URL environment variable is required"
end
```

### Setting Validation

```crystal
Azu.configure do |config|
  config.port = ENV["PORT"]?.try(&.to_i) || 3000
  raise "Port must be between 1 and 65535" unless (1..65535).includes?(config.port)
end
```

## Configuration Inheritance

### Base Configuration

```crystal
# config/base.cr
module BaseConfig
  def self.configure
    Azu.configure do |config|
      config.host = "0.0.0.0"
      config.debug = false
    end
  end
end
```

### Environment-specific Configuration

```crystal
# config/development.cr
module DevelopmentConfig
  def self.configure
    BaseConfig.configure

    Azu.configure do |config|
      config.debug = true
      config.port = 3000
    end
  end
end
```

## Configuration Testing

### Test Configuration

```crystal
# spec/spec_helper.cr
Azu.configure do |config|
  config.port = 0  # Random port for testing
  config.debug = false
  config.database_url = "sqlite3://:memory:"
end
```

### Configuration Validation Tests

```crystal
describe "Configuration" do
  it "validates required settings" do
    expect_raises(ArgumentError) do
      Azu.configure do |config|
        config.port = 0  # Invalid port
      end
    end
  end
end
```

## Next Steps

- Learn about [Error Handling](errors.md)
- Explore [Performance Optimization](performance.md)
- Understand [Environment Management](environments.md)
- See [Security Best Practices](security.md)

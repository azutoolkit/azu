# Configuration Options API Reference

This document provides a comprehensive reference for all configuration options available in Azu, including server settings, middleware configuration, and environment-specific options.

## Server Configuration

### Basic Server Settings

```crystal
class Azu::Configuration
  # Server binding configuration
  HOST = ENV["HOST"]? || "0.0.0.0"
  PORT = (ENV["PORT"]? || "3000").to_i

  # Worker configuration
  WORKERS = (ENV["WORKERS"]? || "1").to_i

  # SSL/TLS configuration
  SSL_ENABLED = (ENV["SSL_ENABLED"]? || "false").downcase == "true"
  SSL_CERT_PATH = ENV["SSL_CERT_PATH"]?
  SSL_KEY_PATH = ENV["SSL_KEY_PATH"]?

  # Request configuration
  MAX_REQUEST_SIZE = (ENV["MAX_REQUEST_SIZE"]? || "10MB").to_i64
  REQUEST_TIMEOUT = (ENV["REQUEST_TIMEOUT"]? || "30").to_i

  # Response configuration
  COMPRESSION_ENABLED = (ENV["COMPRESSION_ENABLED"]? || "true").downcase == "true"
  COMPRESSION_LEVEL = (ENV["COMPRESSION_LEVEL"]? || "6").to_i
end
```

### Environment Variables

| Variable              | Default   | Description                 |
| --------------------- | --------- | --------------------------- |
| `HOST`                | `0.0.0.0` | Host to bind the server to  |
| `PORT`                | `3000`    | Port to bind the server to  |
| `WORKERS`             | `1`       | Number of worker processes  |
| `SSL_ENABLED`         | `false`   | Enable SSL/TLS              |
| `SSL_CERT_PATH`       | `nil`     | Path to SSL certificate     |
| `SSL_KEY_PATH`        | `nil`     | Path to SSL private key     |
| `MAX_REQUEST_SIZE`    | `10MB`    | Maximum request size        |
| `REQUEST_TIMEOUT`     | `30`      | Request timeout in seconds  |
| `COMPRESSION_ENABLED` | `true`    | Enable response compression |
| `COMPRESSION_LEVEL`   | `6`       | Compression level (1-9)     |

## Application Configuration

### Application Settings

```crystal
class Azu::Configuration
  # Application metadata
  APP_NAME = ENV["APP_NAME"]? || "Azu Application"
  APP_VERSION = ENV["APP_VERSION"]? || "1.0.0"
  APP_ENV = ENV["APP_ENV"]? || "development"

  # Secret configuration
  SECRET_KEY_BASE = ENV["SECRET_KEY_BASE"]? || generate_secret_key

  # Session configuration
  SESSION_SECRET = ENV["SESSION_SECRET"]? || SECRET_KEY_BASE
  SESSION_TIMEOUT = (ENV["SESSION_TIMEOUT"]? || "3600").to_i

  # Cookie configuration
  COOKIE_SECURE = (ENV["COOKIE_SECURE"]? || "false").downcase == "true"
  COOKIE_HTTP_ONLY = (ENV["COOKIE_HTTP_ONLY"]? || "true").downcase == "true"
  COOKIE_SAME_SITE = ENV["COOKIE_SAME_SITE"]? || "Lax"
end
```

### Environment Variables

| Variable           | Default           | Description                 |
| ------------------ | ----------------- | --------------------------- |
| `APP_NAME`         | `Azu Application` | Application name            |
| `APP_VERSION`      | `1.0.0`           | Application version         |
| `APP_ENV`          | `development`     | Application environment     |
| `SECRET_KEY_BASE`  | `auto-generated`  | Secret key for encryption   |
| `SESSION_SECRET`   | `SECRET_KEY_BASE` | Session encryption secret   |
| `SESSION_TIMEOUT`  | `3600`            | Session timeout in seconds  |
| `COOKIE_SECURE`    | `false`           | Secure cookies (HTTPS only) |
| `COOKIE_HTTP_ONLY` | `true`            | HTTP-only cookies           |
| `COOKIE_SAME_SITE` | `Lax`             | SameSite cookie policy      |

## Database Configuration

### Database Settings

```crystal
class Azu::Configuration
  # Database connection
  DATABASE_URL = ENV["DATABASE_URL"]? || "sqlite://./app.db"
  DATABASE_POOL_SIZE = (ENV["DATABASE_POOL_SIZE"]? || "5").to_i
  DATABASE_POOL_TIMEOUT = (ENV["DATABASE_POOL_TIMEOUT"]? || "5.0").to_f
  DATABASE_MAX_RETRIES = (ENV["DATABASE_MAX_RETRIES"]? || "3").to_i

  # Database SSL
  DATABASE_SSL_MODE = ENV["DATABASE_SSL_MODE"]? || "disable"
  DATABASE_SSL_CERT = ENV["DATABASE_SSL_CERT"]?
  DATABASE_SSL_KEY = ENV["DATABASE_SSL_KEY"]?
  DATABASE_SSL_CA = ENV["DATABASE_SSL_CA"]?
end
```

### Environment Variables

| Variable                | Default             | Description                                         |
| ----------------------- | ------------------- | --------------------------------------------------- |
| `DATABASE_URL`          | `sqlite://./app.db` | Database connection URL                             |
| `DATABASE_POOL_SIZE`    | `5`                 | Connection pool size                                |
| `DATABASE_POOL_TIMEOUT` | `5.0`               | Pool checkout timeout                               |
| `DATABASE_MAX_RETRIES`  | `3`                 | Maximum connection retries                          |
| `DATABASE_SSL_MODE`     | `disable`           | SSL mode (disable, require, verify-ca, verify-full) |
| `DATABASE_SSL_CERT`     | `nil`               | SSL certificate path                                |
| `DATABASE_SSL_KEY`      | `nil`               | SSL private key path                                |
| `DATABASE_SSL_CA`       | `nil`               | SSL CA certificate path                             |

## Redis Configuration

### Redis Settings

```crystal
class Azu::Configuration
  # Redis connection
  REDIS_URL = ENV["REDIS_URL"]? || "redis://localhost:6379"
  REDIS_DATABASE = (ENV["REDIS_DATABASE"]? || "0").to_i
  REDIS_POOL_SIZE = (ENV["REDIS_POOL_SIZE"]? || "5").to_i

  # Redis SSL
  REDIS_SSL_ENABLED = (ENV["REDIS_SSL_ENABLED"]? || "false").downcase == "true"
  REDIS_SSL_CERT = ENV["REDIS_SSL_CERT"]?
  REDIS_SSL_KEY = ENV["REDIS_SSL_KEY"]?
end
```

### Environment Variables

| Variable            | Default                  | Description                |
| ------------------- | ------------------------ | -------------------------- |
| `REDIS_URL`         | `redis://localhost:6379` | Redis connection URL       |
| `REDIS_DATABASE`    | `0`                      | Redis database number      |
| `REDIS_POOL_SIZE`   | `5`                      | Redis connection pool size |
| `REDIS_SSL_ENABLED` | `false`                  | Enable Redis SSL           |
| `REDIS_SSL_CERT`    | `nil`                    | Redis SSL certificate path |
| `REDIS_SSL_KEY`     | `nil`                    | Redis SSL private key path |

## Logging Configuration

### Logging Settings

```crystal
class Azu::Configuration
  # Logging levels
  LOG_LEVEL = ENV["LOG_LEVEL"]? || default_log_level
  LOG_FORMAT = ENV["LOG_FORMAT"]? || "json"

  # Log output
  LOG_FILE = ENV["LOG_FILE"]?
  LOG_MAX_SIZE = (ENV["LOG_MAX_SIZE"]? || "100MB").to_i64
  LOG_MAX_FILES = (ENV["LOG_MAX_FILES"]? || "5").to_i

  # Structured logging
  LOG_STRUCTURED = (ENV["LOG_STRUCTURED"]? || "true").downcase == "true"
  LOG_REQUEST_ID = (ENV["LOG_REQUEST_ID"]? || "true").downcase == "true"
end
```

### Environment Variables

| Variable         | Default | Description                          |
| ---------------- | ------- | ------------------------------------ |
| `LOG_LEVEL`      | `info`  | Log level (debug, info, warn, error) |
| `LOG_FORMAT`     | `json`  | Log format (json, text)              |
| `LOG_FILE`       | `nil`   | Log file path                        |
| `LOG_MAX_SIZE`   | `100MB` | Maximum log file size                |
| `LOG_MAX_FILES`  | `5`     | Maximum number of log files          |
| `LOG_STRUCTURED` | `true`  | Enable structured logging            |
| `LOG_REQUEST_ID` | `true`  | Include request ID in logs           |

## Security Configuration

### Security Settings

```crystal
class Azu::Configuration
  # CORS configuration
  CORS_ORIGINS = parse_cors_origins
  CORS_METHODS = ENV["CORS_METHODS"]? || "GET,POST,PUT,DELETE,OPTIONS"
  CORS_HEADERS = ENV["CORS_HEADERS"]? || "Content-Type,Authorization"
  CORS_CREDENTIALS = (ENV["CORS_CREDENTIALS"]? || "false").downcase == "true"

  # CSRF protection
  CSRF_ENABLED = (ENV["CSRF_ENABLED"]? || "true").downcase == "true"
  CSRF_SECRET = ENV["CSRF_SECRET"]? || SECRET_KEY_BASE
  CSRF_TOKEN_LENGTH = (ENV["CSRF_TOKEN_LENGTH"]? || "32").to_i

  # Rate limiting
  RATE_LIMIT_ENABLED = (ENV["RATE_LIMIT_ENABLED"]? || "true").downcase == "true"
  RATE_LIMIT_REQUESTS_PER_MINUTE = (ENV["RATE_LIMIT_REQUESTS_PER_MINUTE"]? || "60").to_i
  RATE_LIMIT_REQUESTS_PER_HOUR = (ENV["RATE_LIMIT_REQUESTS_PER_HOUR"]? || "1000").to_i
end
```

### Environment Variables

| Variable                         | Default                       | Description            |
| -------------------------------- | ----------------------------- | ---------------------- |
| `CORS_ORIGINS`                   | `*`                           | Allowed CORS origins   |
| `CORS_METHODS`                   | `GET,POST,PUT,DELETE,OPTIONS` | Allowed CORS methods   |
| `CORS_HEADERS`                   | `Content-Type,Authorization`  | Allowed CORS headers   |
| `CORS_CREDENTIALS`               | `false`                       | Allow CORS credentials |
| `CSRF_ENABLED`                   | `true`                        | Enable CSRF protection |
| `CSRF_SECRET`                    | `SECRET_KEY_BASE`             | CSRF secret key        |
| `CSRF_TOKEN_LENGTH`              | `32`                          | CSRF token length      |
| `RATE_LIMIT_ENABLED`             | `true`                        | Enable rate limiting   |
| `RATE_LIMIT_REQUESTS_PER_MINUTE` | `60`                          | Requests per minute    |
| `RATE_LIMIT_REQUESTS_PER_HOUR`   | `1000`                        | Requests per hour      |

## Cache Configuration

### Cache Settings

```crystal
class Azu::Configuration
  # Memory cache
  CACHE_ENABLED = (ENV["CACHE_ENABLED"]? || "true").downcase == "true"
  CACHE_MAX_SIZE = (ENV["CACHE_MAX_SIZE"]? || "1000").to_i
  CACHE_DEFAULT_TTL = (ENV["CACHE_DEFAULT_TTL"]? || "300").to_i

  # Redis cache
  CACHE_REDIS_URL = ENV["CACHE_REDIS_URL"]? || REDIS_URL
  CACHE_REDIS_DATABASE = (ENV["CACHE_REDIS_DATABASE"]? || "1").to_i
end
```

### Environment Variables

| Variable               | Default     | Description                  |
| ---------------------- | ----------- | ---------------------------- |
| `CACHE_ENABLED`        | `true`      | Enable caching               |
| `CACHE_MAX_SIZE`       | `1000`      | Maximum cache entries        |
| `CACHE_DEFAULT_TTL`    | `300`       | Default cache TTL in seconds |
| `CACHE_REDIS_URL`      | `REDIS_URL` | Redis cache URL              |
| `CACHE_REDIS_DATABASE` | `1`         | Redis cache database         |

## Email Configuration

### Email Settings

```crystal
class Azu::Configuration
  # SMTP configuration
  SMTP_HOST = ENV["SMTP_HOST"]?
  SMTP_PORT = (ENV["SMTP_PORT"]? || "587").to_i
  SMTP_USERNAME = ENV["SMTP_USERNAME"]?
  SMTP_PASSWORD = ENV["SMTP_PASSWORD"]?
  SMTP_TLS = (ENV["SMTP_TLS"]? || "true").downcase == "true"

  # Email defaults
  EMAIL_FROM = ENV["EMAIL_FROM"]? || "noreply@example.com"
  EMAIL_REPLY_TO = ENV["EMAIL_REPLY_TO"]?
end
```

### Environment Variables

| Variable         | Default               | Description            |
| ---------------- | --------------------- | ---------------------- |
| `SMTP_HOST`      | `nil`                 | SMTP server host       |
| `SMTP_PORT`      | `587`                 | SMTP server port       |
| `SMTP_USERNAME`  | `nil`                 | SMTP username          |
| `SMTP_PASSWORD`  | `nil`                 | SMTP password          |
| `SMTP_TLS`       | `true`                | Enable SMTP TLS        |
| `EMAIL_FROM`     | `noreply@example.com` | Default from email     |
| `EMAIL_REPLY_TO` | `nil`                 | Default reply-to email |

## File Upload Configuration

### File Upload Settings

```crystal
class Azu::Configuration
  # File upload limits
  UPLOAD_MAX_SIZE = (ENV["UPLOAD_MAX_SIZE"]? || "10MB").to_i64
  UPLOAD_ALLOWED_TYPES = parse_allowed_types
  UPLOAD_STORAGE_PATH = ENV["UPLOAD_STORAGE_PATH"]? || "uploads"

  # Cloud storage
  CLOUD_STORAGE_PROVIDER = ENV["CLOUD_STORAGE_PROVIDER"]? || "local"
  CLOUD_STORAGE_BUCKET = ENV["CLOUD_STORAGE_BUCKET"]?
  CLOUD_STORAGE_REGION = ENV["CLOUD_STORAGE_REGION"]?
end
```

### Environment Variables

| Variable                 | Default                | Description            |
| ------------------------ | ---------------------- | ---------------------- |
| `UPLOAD_MAX_SIZE`        | `10MB`                 | Maximum upload size    |
| `UPLOAD_ALLOWED_TYPES`   | `jpg,jpeg,png,gif,pdf` | Allowed file types     |
| `UPLOAD_STORAGE_PATH`    | `uploads`              | Local storage path     |
| `CLOUD_STORAGE_PROVIDER` | `local`                | Cloud storage provider |
| `CLOUD_STORAGE_BUCKET`   | `nil`                  | Cloud storage bucket   |
| `CLOUD_STORAGE_REGION`   | `nil`                  | Cloud storage region   |

## Configuration Classes

### Environment-Specific Configuration

```crystal
class Configuration
  def self.load_environment_config
    case APP_ENV
    when "development"
      load_development_config
    when "staging"
      load_staging_config
    when "production"
      load_production_config
    when "test"
      load_test_config
    end
  end

  private def self.load_development_config
    # Development-specific settings
    LOG_LEVEL = "debug"
    CORS_ORIGINS = ["http://localhost:3000", "http://localhost:3001"]
    CORS_CREDENTIALS = true
    CSRF_ENABLED = false
    RATE_LIMIT_ENABLED = false
  end

  private def self.load_staging_config
    # Staging-specific settings
    LOG_LEVEL = "info"
    CORS_ORIGINS = ["https://staging.example.com"]
    CORS_CREDENTIALS = true
    CSRF_ENABLED = true
    RATE_LIMIT_ENABLED = true
    RATE_LIMIT_REQUESTS_PER_MINUTE = 100
  end

  private def self.load_production_config
    # Production-specific settings
    LOG_LEVEL = "warn"
    CORS_ORIGINS = ["https://example.com"]
    CORS_CREDENTIALS = true
    CSRF_ENABLED = true
    RATE_LIMIT_ENABLED = true
    RATE_LIMIT_REQUESTS_PER_MINUTE = 60
    COOKIE_SECURE = true
    SSL_ENABLED = true
  end

  private def self.load_test_config
    # Test-specific settings
    LOG_LEVEL = "error"
    DATABASE_URL = "sqlite://./test.db"
    CACHE_ENABLED = false
    RATE_LIMIT_ENABLED = false
  end
end
```

### Configuration Validation

```crystal
class ConfigurationValidator
  def self.validate!
    validate_required_vars
    validate_database_config
    validate_redis_config
    validate_security_config
  end

  private def self.validate_required_vars
    required_vars = {
      "production" => ["DATABASE_URL", "SECRET_KEY_BASE", "REDIS_URL"],
      "staging" => ["DATABASE_URL", "SECRET_KEY_BASE"],
      "development" => [],
      "test" => []
    }

    env = APP_ENV
    missing = required_vars[env]?.select { |var| ENV[var]?.nil? } || [] of String

    unless missing.empty?
      raise "Missing required environment variables for #{env}: #{missing.join(", ")}"
    end
  end

  private def self.validate_database_config
    return unless DATABASE_URL

    begin
      # Test database connection
      DB.open(DATABASE_URL) { |db| db.scalar("SELECT 1") }
    rescue ex
      raise "Invalid database configuration: #{ex.message}"
    end
  end

  private def self.validate_redis_config
    return unless REDIS_URL

    begin
      # Test Redis connection
      redis = Redis::Client.new(url: REDIS_URL)
      redis.ping
    rescue ex
      raise "Invalid Redis configuration: #{ex.message}"
    end
  end

  private def self.validate_security_config
    if APP_ENV == "production"
      if SECRET_KEY_BASE == "auto-generated"
        raise "SECRET_KEY_BASE must be set in production"
      end

      if !SSL_ENABLED && !ENV["DISABLE_SSL_REQUIREMENT"]?
        raise "SSL must be enabled in production"
      end
    end
  end
end
```

### Configuration Loading

```crystal
class ConfigurationLoader
  def self.load!
    # Load environment-specific configuration
    Configuration.load_environment_config

    # Validate configuration
    ConfigurationValidator.validate!

    # Initialize components
    initialize_logging
    initialize_database
    initialize_redis
    initialize_cache
  end

  private def self.initialize_logging
    Log.setup do |c|
      case LOG_LEVEL
      when "debug"
        c.bind("*", :debug, Log::IOBackend.new)
      when "info"
        c.bind("*", :info, Log::IOBackend.new)
      when "warn"
        c.bind("*", :warn, Log::IOBackend.new)
      when "error"
        c.bind("*", :error, Log::IOBackend.new)
      end

      if LOG_FILE
        c.bind("*", LOG_LEVEL.to_sym, Log::IOBackend.new(File.new(LOG_FILE, "a")))
      end
    end
  end

  private def self.initialize_database
    # Database initialization code
  end

  private def self.initialize_redis
    # Redis initialization code
  end

  private def self.initialize_cache
    # Cache initialization code
  end
end
```

## Configuration Usage

### Application Startup

```crystal
# Load configuration before starting the application
ConfigurationLoader.load!

# Start the application with configuration
Azu.start do |app|
  # Application setup
end
```

### Environment-Specific Configuration

```crystal
# Use configuration in your application
if Configuration::APP_ENV == "development"
  # Development-specific code
end

# Use configuration values
database_url = Configuration::DATABASE_URL
redis_url = Configuration::REDIS_URL
log_level = Configuration::LOG_LEVEL
```

### Configuration Testing

```crystal
describe "Configuration" do
  it "loads development configuration correctly" do
    ENV["APP_ENV"] = "development"
    ConfigurationLoader.load!

    assert Configuration::LOG_LEVEL == "debug"
    assert Configuration::CSRF_ENABLED == false
    assert Configuration::RATE_LIMIT_ENABLED == false
  end

  it "loads production configuration correctly" do
    ENV["APP_ENV"] = "production"
    ENV["SECRET_KEY_BASE"] = "test-secret"
    ConfigurationLoader.load!

    assert Configuration::LOG_LEVEL == "warn"
    assert Configuration::CSRF_ENABLED == true
    assert Configuration::RATE_LIMIT_ENABLED == true
  end

  it "validates required environment variables" do
    ENV["APP_ENV"] = "production"
    ENV.delete("SECRET_KEY_BASE")

    expect_raises(Exception, "Missing required environment variables") do
      ConfigurationLoader.load!
    end
  end
end
```

## Next Steps

- [Core Modules](api-reference/core.md) - Core framework modules
- [Handler Classes](api-reference/handlers.md) - Built-in middleware handlers
- [Environment Management](advanced/environments.md) - Environment-specific configuration
- [Advanced Usage](advanced.md) - Advanced configuration patterns

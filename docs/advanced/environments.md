# Environment Management

Environment management in Azu provides a robust way to handle different deployment environments with appropriate configurations, security settings, and feature flags. With support for multiple environments, configuration inheritance, and environment-specific settings, you can maintain consistent deployments across development, staging, and production.

## What is Environment Management?

Environment management in Azu provides:

- **Multiple Environments**: Development, staging, production, and custom environments
- **Configuration Inheritance**: Base configuration with environment-specific overrides
- **Security Settings**: Environment-specific security configurations
- **Feature Flags**: Enable/disable features based on environment
- **Environment Variables**: Secure configuration through environment variables

## Basic Environment Configuration

### Environment Detection

```crystal
module MyApp
  include Azu

  configure do |config|
    # Environment detection
    config.env = ENV.fetch("AZU_ENV", "development")

    # Environment-specific configuration
    case config.env
    when "development"
      configure_development(config)
    when "staging"
      configure_staging(config)
    when "production"
      configure_production(config)
    else
      configure_default(config)
    end
  end

  private def self.configure_development(config)
    config.debug = true
    config.log_level = Log::Severity::DEBUG
    config.template_hot_reload = true
    config.cache.enabled = false
  end

  private def self.configure_staging(config)
    config.debug = false
    config.log_level = Log::Severity::INFO
    config.template_hot_reload = false
    config.cache.enabled = true
    config.cache.backend = :redis
  end

  private def self.configure_production(config)
    config.debug = false
    config.log_level = Log::Severity::WARN
    config.template_hot_reload = false
    config.cache.enabled = true
    config.cache.backend = :redis
    config.performance_monitoring = true
  end
end
```

### Environment Variables

```crystal
class EnvironmentConfig
  def self.database_url : String
    ENV.fetch("DATABASE_URL", "sqlite://./db/development.sqlite")
  end

  def self.redis_url : String
    ENV.fetch("REDIS_URL", "redis://localhost:6379")
  end

  def self.secret_key : String
    ENV.fetch("SECRET_KEY", "development-secret-key")
  end

  def self.api_key : String?
    ENV["API_KEY"]?
  end

  def self.debug_mode : Bool
    ENV.fetch("DEBUG", "false") == "true"
  end

  def self.log_level : Log::Severity
    case ENV.fetch("LOG_LEVEL", "info").downcase
    when "debug"
      Log::Severity::DEBUG
    when "info"
      Log::Severity::INFO
    when "warn"
      Log::Severity::WARN
    when "error"
      Log::Severity::ERROR
    else
      Log::Severity::INFO
    end
  end
end
```

## Environment-Specific Configuration

### Development Environment

```crystal
class DevelopmentConfig
  def self.configure(config)
    # Development-specific settings
    config.host = "localhost"
    config.port = 3000
    config.debug = true
    config.log_level = Log::Severity::DEBUG

    # Development features
    config.template_hot_reload = true
    config.auto_reload = true
    config.cache.enabled = false

    # Development database
    config.database.url = "sqlite://./db/development.sqlite"
    config.database.pool_size = 5

    # Development logging
    config.logging.outputs = [:console]
    config.logging.async = false

    # Development security
    config.security.csrf_protection = false
    config.security.rate_limiting = false
  end
end
```

### Staging Environment

```crystal
class StagingConfig
  def self.configure(config)
    # Staging-specific settings
    config.host = "0.0.0.0"
    config.port = ENV.fetch("PORT", "3000").to_i
    config.debug = false
    config.log_level = Log::Severity::INFO

    # Staging features
    config.template_hot_reload = false
    config.auto_reload = false
    config.cache.enabled = true

    # Staging database
    config.database.url = ENV.fetch("DATABASE_URL", "postgresql://localhost/staging")
    config.database.pool_size = 10

    # Staging logging
    config.logging.outputs = [:console, :file]
    config.logging.async = true
    config.logging.file_path = "/var/log/app/staging.log"

    # Staging security
    config.security.csrf_protection = true
    config.security.rate_limiting = true
    config.security.rate_limit = 1000  # requests per hour
  end
end
```

### Production Environment

```crystal
class ProductionConfig
  def self.configure(config)
    # Production-specific settings
    config.host = "0.0.0.0"
    config.port = ENV.fetch("PORT", "8080").to_i
    config.debug = false
    config.log_level = Log::Severity::WARN

    # Production features
    config.template_hot_reload = false
    config.auto_reload = false
    config.cache.enabled = true
    config.performance_monitoring = true

    # Production database
    config.database.url = ENV.fetch("DATABASE_URL")
    config.database.pool_size = 20
    config.database.ssl = true

    # Production logging
    config.logging.outputs = [:file, :external]
    config.logging.async = true
    config.logging.file_path = "/var/log/app/production.log"
    config.logging.external_endpoint = ENV.fetch("LOG_ENDPOINT")

    # Production security
    config.security.csrf_protection = true
    config.security.rate_limiting = true
    config.security.rate_limit = 10000  # requests per hour
    config.security.ssl_required = true
    config.security.secure_cookies = true
  end
end
```

## Feature Flags

### Feature Flag System

```crystal
class FeatureFlags
  def self.is_enabled?(feature : String) : Bool
    case feature
    when "user_registration"
      user_registration_enabled?
    when "email_notifications"
      email_notifications_enabled?
    when "advanced_search"
      advanced_search_enabled?
    when "beta_features"
      beta_features_enabled?
    else
      false
    end
  end

  private def self.user_registration_enabled? : Bool
    ENV.fetch("FEATURE_USER_REGISTRATION", "true") == "true"
  end

  private def self.email_notifications_enabled? : Bool
    ENV.fetch("FEATURE_EMAIL_NOTIFICATIONS", "false") == "true"
  end

  private def self.advanced_search_enabled? : Bool
    ENV.fetch("FEATURE_ADVANCED_SEARCH", "false") == "true"
  end

  private def self.beta_features_enabled? : Bool
    ENV.fetch("FEATURE_BETA_FEATURES", "false") == "true"
  end
end
```

### Feature Flag Usage

```crystal
class UserRegistrationEndpoint
  include Azu::Endpoint(UserRegistrationRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Check feature flag
    unless FeatureFlags.is_enabled?("user_registration")
      raise Azu::Response::Forbidden.new("User registration is disabled")
    end

    # Process registration
    user = create_user(user_registration_request)

    # Send email notification if enabled
    if FeatureFlags.is_enabled?("email_notifications")
      send_welcome_email(user)
    end

    UserResponse.new(user)
  end
end
```

## Environment-Specific Security

### Security Configuration

```crystal
class SecurityConfig
  def self.configure_security(config)
    case config.env
    when "development"
      configure_development_security(config)
    when "staging"
      configure_staging_security(config)
    when "production"
      configure_production_security(config)
    end
  end

  private def self.configure_development_security(config)
    # Development security (relaxed)
    config.security.csrf_protection = false
    config.security.rate_limiting = false
    config.security.ssl_required = false
    config.security.secure_cookies = false
    config.security.cors.origins = ["http://localhost:3000", "http://localhost:3001"]
  end

  private def self.configure_staging_security(config)
    # Staging security (moderate)
    config.security.csrf_protection = true
    config.security.rate_limiting = true
    config.security.rate_limit = 1000
    config.security.ssl_required = false
    config.security.secure_cookies = false
    config.security.cors.origins = ["https://staging.example.com"]
  end

  private def self.configure_production_security(config)
    # Production security (strict)
    config.security.csrf_protection = true
    config.security.rate_limiting = true
    config.security.rate_limit = 10000
    config.security.ssl_required = true
    config.security.secure_cookies = true
    config.security.cors.origins = ["https://example.com"]
    config.security.cors.credentials = true
    config.security.cors.max_age = 86400
  end
end
```

### Environment-Specific Secrets

```crystal
class SecretManager
  def self.get_secret(key : String) : String
    case Azu.env
    when "development"
      get_development_secret(key)
    when "staging"
      get_staging_secret(key)
    when "production"
      get_production_secret(key)
    else
      raise "Unknown environment: #{Azu.env}"
    end
  end

  private def self.get_development_secret(key : String) : String
    # Development secrets (can be hardcoded or from .env file)
    case key
    when "database_password"
      "development_password"
    when "api_key"
      "development_api_key"
    when "secret_key"
      "development_secret_key"
    else
      raise "Unknown secret: #{key}"
    end
  end

  private def self.get_staging_secret(key : String) : String
    # Staging secrets (from environment variables)
    ENV.fetch("STAGING_#{key.upcase}")
  end

  private def self.get_production_secret(key : String) : String
    # Production secrets (from secure secret management)
    ENV.fetch("PRODUCTION_#{key.upcase}")
  end
end
```

## Environment-Specific Logging

### Logging Configuration

```crystal
class LoggingConfig
  def self.configure_logging(config)
    case config.env
    when "development"
      configure_development_logging(config)
    when "staging"
      configure_staging_logging(config)
    when "production"
      configure_production_logging(config)
    end
  end

  private def self.configure_development_logging(config)
    # Development logging (verbose)
    config.logging.level = Log::Severity::DEBUG
    config.logging.outputs = [:console]
    config.logging.async = false
    config.logging.colors = true
    config.logging.timestamps = true
  end

  private def self.configure_staging_logging(config)
    # Staging logging (moderate)
    config.logging.level = Log::Severity::INFO
    config.logging.outputs = [:console, :file]
    config.logging.async = true
    config.logging.file_path = "/var/log/app/staging.log"
    config.logging.colors = false
    config.logging.timestamps = true
  end

  private def self.configure_production_logging(config)
    # Production logging (minimal)
    config.logging.level = Log::Severity::WARN
    config.logging.outputs = [:file, :external]
    config.logging.async = true
    config.logging.file_path = "/var/log/app/production.log"
    config.logging.external_endpoint = ENV.fetch("LOG_ENDPOINT")
    config.logging.colors = false
    config.logging.timestamps = true
    config.logging.structured = true
  end
end
```

## Environment Validation

### Environment Health Check

```crystal
class EnvironmentHealthCheck
  def self.check_environment : Hash(String, JSON::Any)
    {
      "environment" => Azu.env,
      "configuration" => check_configuration,
      "secrets" => check_secrets,
      "database" => check_database,
      "cache" => check_cache,
      "external_services" => check_external_services
    }
  end

  private def self.check_configuration : Hash(String, JSON::Any)
    {
      "host" => Azu.config.host,
      "port" => Azu.config.port,
      "debug" => Azu.config.debug,
      "log_level" => Azu.config.log_level.to_s
    }
  end

  private def self.check_secrets : Hash(String, JSON::Any)
    {
      "database_url" => EnvironmentConfig.database_url.present?,
      "secret_key" => EnvironmentConfig.secret_key.present?,
      "api_key" => EnvironmentConfig.api_key.present?
    }
  end

  private def self.check_database : Hash(String, JSON::Any)
    begin
      User.count
      {"status" => "healthy", "connection" => "ok"}
    rescue e
      {"status" => "unhealthy", "error" => e.message}
    end
  end

  private def self.check_cache : Hash(String, JSON::Any)
    begin
      Azu.cache.set("health_check", "ok", ttl: 1.minute)
      result = Azu.cache.get("health_check")
      {"status" => result == "ok" ? "healthy" : "unhealthy"}
    rescue e
      {"status" => "unhealthy", "error" => e.message}
    end
  end

  private def self.check_external_services : Hash(String, JSON::Any)
    {
      "email_service" => check_email_service,
      "payment_service" => check_payment_service,
      "analytics_service" => check_analytics_service
    }
  end
end
```

## Environment-Specific Testing

### Test Environment Configuration

```crystal
class TestConfig
  def self.configure_test_environment(config)
    # Test-specific settings
    config.env = "test"
    config.debug = false
    config.log_level = Log::Severity::ERROR

    # Test database
    config.database.url = "sqlite://./db/test.sqlite"
    config.database.pool_size = 1

    # Test cache
    config.cache.enabled = false

    # Test logging
    config.logging.outputs = [:console]
    config.logging.async = false

    # Test security
    config.security.csrf_protection = false
    config.security.rate_limiting = false
  end
end
```

### Environment-Specific Test Helpers

```crystal
class TestHelpers
  def self.setup_test_environment
    # Set test environment
    ENV["AZU_ENV"] = "test"

    # Configure test database
    ENV["DATABASE_URL"] = "sqlite://./db/test.sqlite"

    # Configure test cache
    ENV["CACHE_ENABLED"] = "false"

    # Configure test logging
    ENV["LOG_LEVEL"] = "error"
  end

  def self.cleanup_test_environment
    # Clean up test database
    File.delete("./db/test.sqlite") if File.exists?("./db/test.sqlite")

    # Clean up test cache
    Azu.cache.clear if Azu.cache.enabled?
  end
end
```

## Best Practices

### 1. Use Environment Variables

```crystal
# Good: Use environment variables
config.database.url = ENV.fetch("DATABASE_URL")
config.redis.url = ENV.fetch("REDIS_URL")
config.secret_key = ENV.fetch("SECRET_KEY")

# Avoid: Hardcoded values
config.database.url = "postgresql://localhost/production"
config.redis.url = "redis://localhost:6379"
config.secret_key = "hardcoded-secret"
```

### 2. Validate Environment Configuration

```crystal
# Good: Validate configuration
def validate_environment_config
  required_vars = ["DATABASE_URL", "SECRET_KEY"]
  missing_vars = required_vars.select { |var| ENV[var]?.nil? }

  if missing_vars.any?
    raise "Missing required environment variables: #{missing_vars.join(", ")}"
  end
end

# Avoid: No validation
# No validation - can cause runtime errors
```

### 3. Use Feature Flags

```crystal
# Good: Use feature flags
if FeatureFlags.is_enabled?("user_registration")
  # Enable user registration
end

# Avoid: Environment-specific code
if Azu.env == "production"
  # Production-specific code
end
```

### 4. Secure Environment Variables

```crystal
# Good: Secure environment variables
config.secret_key = ENV.fetch("SECRET_KEY")
config.api_key = ENV.fetch("API_KEY")

# Avoid: Exposing secrets
config.secret_key = "development-secret"  # Exposed in code
```

### 5. Test Environment Configuration

```crystal
# Good: Test environment configuration
describe "Environment Configuration" do
  it "configures development environment" do
    ENV["AZU_ENV"] = "development"
    # Test development configuration
  end

  it "configures production environment" do
    ENV["AZU_ENV"] = "production"
    # Test production configuration
  end
end

# Avoid: No environment testing
# No testing - can cause deployment issues
```

## Next Steps

Now that you understand environment management:

1. **[Configuration](configuration.md)** - Configure your application
2. **[Security](security.md)** - Implement security measures
3. **[Deployment](../deployment/production.md)** - Deploy with environment management
4. **[Testing](../testing.md)** - Test environment configurations
5. **[Monitoring](monitoring.md)** - Monitor environment health

---

_Environment management in Azu provides a robust way to handle different deployment environments. With configuration inheritance, feature flags, and environment-specific settings, you can maintain consistent deployments across all environments._

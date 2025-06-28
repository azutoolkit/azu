# Environment Management in Azu

Azu provides comprehensive environment management capabilities, allowing you to configure your application differently across development, staging, and production environments. This guide covers environment-specific configuration, feature flags, and deployment strategies.

## Overview

```mermaid
graph TD
    A[Environment Detection] --> B[Configuration Loading]
    B --> C[Feature Flags]
    C --> D[Environment-Specific Behavior]

    E[Development] --> B
    F[Staging] --> B
    G[Production] --> B
    H[Custom] --> B
```

## Environment Detection

### Automatic Environment Detection

```crystal
class EnvironmentManager
  # Environment constants
  DEVELOPMENT = "development"
  STAGING = "staging"
  PRODUCTION = "production"
  TEST = "test"

  # Environment detection
  def self.current : String
    ENV["AZU_ENV"]? || ENV["CRYSTAL_ENV"]? || DEVELOPMENT
  end

  def self.development? : Bool
    current == DEVELOPMENT
  end

  def self.staging? : Bool
    current == STAGING
  end

  def self.production? : Bool
    current == PRODUCTION
  end

  def self.test? : Bool
    current == TEST
  end

  def self.custom?(name : String) : Bool
    current == name
  end
end

# Usage in endpoints
struct EnvironmentAwareEndpoint
  include Endpoint(EnvironmentRequest, EnvironmentResponse)

  get "/api/environment"

  def call : EnvironmentResponse
    data = {
      "environment" => EnvironmentManager.current,
      "is_development" => EnvironmentManager.development?,
      "is_production" => EnvironmentManager.production?,
      "debug_enabled" => EnvironmentManager.development?,
      "timestamp" => Time.utc.to_unix
    }

    EnvironmentResponse.new(data)
  end
end

struct EnvironmentRequest
  include Request

  def initialize
  end
end

struct EnvironmentResponse
  include Response

  getter data : Hash(String, String | Bool | Int64)

  def initialize(@data)
  end

  def render : String
    data.to_json
  end
end
```

## Configuration Management

### Environment-Specific Configuration

```crystal
class Configuration
  # Database configuration
  DATABASE_URL = ENV["DATABASE_URL"]? || "sqlite://./dev.db"
  DATABASE_POOL_SIZE = (ENV["DATABASE_POOL_SIZE"]? || "5").to_i

  # Redis configuration
  REDIS_URL = ENV["REDIS_URL"]? || "redis://localhost:6379"

  # Application settings
  APP_NAME = ENV["APP_NAME"]? || "Azu App"
  APP_VERSION = ENV["APP_VERSION"]? || "1.0.0"
  APP_SECRET = ENV["APP_SECRET"]? || "dev-secret-key"

  # Server configuration
  HOST = ENV["HOST"]? || "0.0.0.0"
  PORT = (ENV["PORT"]? || "3000").to_i
  WORKERS = (ENV["WORKERS"]? || "1").to_i

  # Logging configuration
  LOG_LEVEL = ENV["LOG_LEVEL"]? || default_log_level
  LOG_FORMAT = ENV["LOG_FORMAT"]? || "json"

  # Security settings
  SSL_ENABLED = (ENV["SSL_ENABLED"]? || "false").downcase == "true"
  SSL_CERT_PATH = ENV["SSL_CERT_PATH"]?
  SSL_KEY_PATH = ENV["SSL_KEY_PATH"]?

  # Feature flags
  FEATURE_FLAGS = load_feature_flags

  private def self.default_log_level : String
    case EnvironmentManager.current
    when EnvironmentManager::DEVELOPMENT
      "debug"
    when EnvironmentManager::STAGING
      "info"
    when EnvironmentManager::PRODUCTION
      "warn"
    else
      "info"
    end
  end

  private def self.load_feature_flags : Hash(String, Bool)
    {
      "beta_features" => EnvironmentManager.development? || EnvironmentManager.staging?,
      "debug_mode" => EnvironmentManager.development?,
      "performance_monitoring" => EnvironmentManager.production?,
      "detailed_logging" => EnvironmentManager.development?,
      "rate_limiting" => EnvironmentManager.production? || EnvironmentManager.staging?
    }
  end
end
```

### Configuration Classes

```crystal
struct DatabaseConfig
  getter url : String
  getter pool_size : Int32
  getter timeout : Time::Span
  getter ssl_mode : String

  def initialize
    @url = ENV["DATABASE_URL"]? || default_url
    @pool_size = (ENV["DATABASE_POOL_SIZE"]? || "5").to_i
    @timeout = Time::Span.new(seconds: (ENV["DATABASE_TIMEOUT"]? || "30").to_i)
    @ssl_mode = ENV["DATABASE_SSL_MODE"]? || default_ssl_mode
  end

  private def default_url : String
    case EnvironmentManager.current
    when EnvironmentManager::DEVELOPMENT
      "sqlite://./dev.db"
    when EnvironmentManager::TEST
      "sqlite://./test.db"
    when EnvironmentManager::STAGING
      "postgresql://staging:pass@localhost/staging_db"
    when EnvironmentManager::PRODUCTION
      "postgresql://prod:pass@prod-host/prod_db"
    else
      "sqlite://./dev.db"
    end
  end

  private def default_ssl_mode : String
    case EnvironmentManager.current
    when EnvironmentManager::PRODUCTION
      "require"
    else
      "disable"
    end
  end
end

struct SecurityConfig
  getter secret_key : String
  getter session_timeout : Time::Span
  getter csrf_enabled : Bool
  getter rate_limit_enabled : Bool
  getter cors_origins : Array(String)

  def initialize
    @secret_key = ENV["SECRET_KEY"]? || default_secret_key
    @session_timeout = Time::Span.new(hours: (ENV["SESSION_TIMEOUT_HOURS"]? || "24").to_i)
    @csrf_enabled = (ENV["CSRF_ENABLED"]? || default_csrf_enabled).downcase == "true"
    @rate_limit_enabled = (ENV["RATE_LIMIT_ENABLED"]? || default_rate_limit_enabled).downcase == "true"
    @cors_origins = parse_cors_origins
  end

  private def default_secret_key : String
    case EnvironmentManager.current
    when EnvironmentManager::DEVELOPMENT
      "dev-secret-key-change-in-production"
    when EnvironmentManager::TEST
      "test-secret-key"
    else
      raise "SECRET_KEY environment variable is required in #{EnvironmentManager.current}"
    end
  end

  private def default_csrf_enabled : String
    case EnvironmentManager.current
    when EnvironmentManager::DEVELOPMENT
      "false"
    else
      "true"
    end
  end

  private def default_rate_limit_enabled : String
    case EnvironmentManager.current
    when EnvironmentManager::DEVELOPMENT
      "false"
    else
      "true"
    end
  end

  private def parse_cors_origins : Array(String)
    origins = ENV["CORS_ORIGINS"]?
    return default_cors_origins unless origins

    origins.split(",").map(&.strip)
  end

  private def default_cors_origins : Array(String)
    case EnvironmentManager.current
    when EnvironmentManager::DEVELOPMENT
      ["http://localhost:3000", "http://localhost:3001"]
    when EnvironmentManager::STAGING
      ["https://staging.example.com"]
    when EnvironmentManager::PRODUCTION
      ["https://example.com", "https://www.example.com"]
    else
      ["http://localhost:3000"]
    end
  end
end
```

## Feature Flags

### Feature Flag System

```crystal
class FeatureFlags
  @@flags = {} of String => Bool
  @@callbacks = {} of String => Array(->)

  def self.enabled?(flag : String) : Bool
    @@flags[flag]? || false
  end

  def self.disabled?(flag : String) : Bool
    !enabled?(flag)
  end

  def self.set(flag : String, enabled : Bool)
    @@flags[flag] = enabled
    notify_callbacks(flag, enabled)
  end

  def self.on_change(flag : String, &block : ->)
    @@callbacks[flag] ||= [] of ->
    @@callbacks[flag] << block
  end

  def self.load_from_env
    # Load feature flags from environment variables
    ENV.each do |key, value|
      if key.starts_with?("FEATURE_")
        flag_name = key[8..-1].downcase  # Remove "FEATURE_" prefix
        enabled = value.downcase == "true"
        set(flag_name, enabled)
      end
    end

    # Set default flags based on environment
    set_default_flags
  end

  private def self.set_default_flags
    case EnvironmentManager.current
    when EnvironmentManager::DEVELOPMENT
      set("debug_mode", true)
      set("beta_features", true)
      set("detailed_logging", true)
      set("performance_monitoring", false)
    when EnvironmentManager::STAGING
      set("debug_mode", false)
      set("beta_features", true)
      set("detailed_logging", true)
      set("performance_monitoring", true)
    when EnvironmentManager::PRODUCTION
      set("debug_mode", false)
      set("beta_features", false)
      set("detailed_logging", false)
      set("performance_monitoring", true)
    end
  end

  private def self.notify_callbacks(flag : String, enabled : Bool)
    if callbacks = @@callbacks[flag]?
      callbacks.each(&.call)
    end
  end
end

# Feature flag usage in endpoints
struct FeatureFlagEndpoint
  include Endpoint(FeatureFlagRequest, FeatureFlagResponse)

  get "/api/features"

  def call : FeatureFlagResponse
    flags = {
      "debug_mode" => FeatureFlags.enabled?("debug_mode"),
      "beta_features" => FeatureFlags.enabled?("beta_features"),
      "detailed_logging" => FeatureFlags.enabled?("detailed_logging"),
      "performance_monitoring" => FeatureFlags.enabled?("performance_monitoring")
    }

    FeatureFlagResponse.new(flags)
  end
end

struct FeatureFlagRequest
  include Request

  def initialize
  end
end

struct FeatureFlagResponse
  include Response

  getter flags : Hash(String, Bool)

  def initialize(@flags)
  end

  def render : String
    flags.to_json
  end
end

# Conditional feature usage
struct ConditionalFeatureEndpoint
  include Endpoint(ConditionalRequest, ConditionalResponse)

  get "/api/conditional-feature"

  def call : ConditionalResponse
    if FeatureFlags.enabled?("beta_features")
      # Beta feature implementation
      data = {
        "feature" => "beta",
        "message" => "This is a beta feature",
        "experimental" => true
      }
    else
      # Standard implementation
      data = {
        "feature" => "standard",
        "message" => "This is the standard feature",
        "experimental" => false
      }
    end

    ConditionalResponse.new(data)
  end
end
```

## Environment-Specific Middleware

### Conditional Middleware

```crystal
class EnvironmentAwareMiddleware
  def self.create_stack : Array(Azu::Handler::Base)
    stack = [] of Azu::Handler::Base

    # Always include these handlers
    stack << Azu::Handler::Rescuer.new
    stack << Azu::Handler::Logger.new

    # Environment-specific middleware
    case EnvironmentManager.current
    when EnvironmentManager::DEVELOPMENT
      stack << Azu::Handler::CORS.new(
        origins: ["http://localhost:3000", "http://localhost:3001"],
        methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
      )
      stack << Azu::Handler::Static.new("public")

    when EnvironmentManager::STAGING
      stack << Azu::Handler::CORS.new(
        origins: ["https://staging.example.com"],
        methods: ["GET", "POST", "PUT", "DELETE"]
      )
      stack << Azu::Handler::Throttle.new(requests_per_minute: 100)
      stack << Azu::Handler::RequestId.new

    when EnvironmentManager::PRODUCTION
      stack << Azu::Handler::CORS.new(
        origins: ["https://example.com"],
        methods: ["GET", "POST", "PUT", "DELETE"]
      )
      stack << Azu::Handler::Throttle.new(requests_per_minute: 60)
      stack << Azu::Handler::RequestId.new
      stack << Azu::Handler::IpSpoofing.new
    end

    stack
  end
end

# Application startup with environment-aware middleware
class Application
  def self.start
    middleware_stack = EnvironmentAwareMiddleware.create_stack

    Azu.start(middleware_stack) do |app|
      # Register routes
      register_routes(app)
    end
  end

  private def self.register_routes(app)
    # Register endpoints based on environment
    if EnvironmentManager.development?
      register_development_routes(app)
    end

    register_production_routes(app)
  end

  private def self.register_development_routes(app)
    # Development-only routes (debug endpoints, etc.)
    app.get("/debug/info") { |context| debug_info(context) }
    app.get("/debug/features") { |context| debug_features(context) }
  end

  private def self.register_production_routes(app)
    # Production routes
    app.get("/api/health") { |context| health_check(context) }
  end
end
```

## Environment-Specific Logging

### Logging Configuration

```crystal
class LoggerConfig
  def self.configure
    case EnvironmentManager.current
    when EnvironmentManager::DEVELOPMENT
      configure_development_logging
    when EnvironmentManager::STAGING
      configure_staging_logging
    when EnvironmentManager::PRODUCTION
      configure_production_logging
    end
  end

  private def self.configure_development_logging
    Log.setup do |c|
      c.bind("*", :debug, Log::IOBackend.new)
      c.bind("azu.*", :debug, Log::IOBackend.new)
    end
  end

  private def self.configure_staging_logging
    Log.setup do |c|
      c.bind("*", :info, Log::IOBackend.new)
      c.bind("azu.*", :debug, Log::IOBackend.new)

      # Add file logging for staging
      c.bind("*", :info, Log::IOBackend.new(File.new("logs/staging.log", "a")))
    end
  end

  private def self.configure_production_logging
    Log.setup do |c|
      c.bind("*", :warn, Log::IOBackend.new)
      c.bind("azu.*", :info, Log::IOBackend.new)

      # Add structured logging for production
      c.bind("*", :warn, Log::IOBackend.new(File.new("logs/production.log", "a")))

      # Add error logging
      c.bind("*", :error, Log::IOBackend.new(File.new("logs/errors.log", "a")))
    end
  end
end

# Usage in endpoints
struct LoggingEndpoint
  include Endpoint(LoggingRequest, LoggingResponse)

  get "/api/logging-test"

  def call : LoggingResponse
    Log.debug { "Debug message from logging test" }
    Log.info { "Info message from logging test" }
    Log.warn { "Warning message from logging test" }
    Log.error { "Error message from logging test" }

    LoggingResponse.new("Logging test completed")
  end
end
```

## Environment Variables Management

### Environment Variable Validation

```crystal
class EnvironmentValidator
  REQUIRED_VARS = {
    EnvironmentManager::PRODUCTION => ["DATABASE_URL", "SECRET_KEY", "REDIS_URL"],
    EnvironmentManager::STAGING => ["DATABASE_URL", "SECRET_KEY"],
    EnvironmentManager::DEVELOPMENT => [],
    EnvironmentManager::TEST => []
  }

  def self.validate!
    missing_vars = find_missing_vars

    unless missing_vars.empty?
      raise "Missing required environment variables for #{EnvironmentManager.current}: #{missing_vars.join(", ")}"
    end
  end

  private def self.find_missing_vars : Array(String)
    required = REQUIRED_VARS[EnvironmentManager.current]? || [] of String

    required.select { |var| ENV[var]?.nil? || ENV[var].empty? }
  end
end

# Application startup with validation
class Application
  def self.start
    # Validate environment variables
    EnvironmentValidator.validate!

    # Load feature flags
    FeatureFlags.load_from_env

    # Configure logging
    LoggerConfig.configure

    # Start application
    middleware_stack = EnvironmentAwareMiddleware.create_stack

    Azu.start(middleware_stack) do |app|
      register_routes(app)
    end
  end
end
```

## Testing Environment Management

### Environment Testing

```crystal
describe "EnvironmentManager" do
  it "detects development environment" do
    ENV["AZU_ENV"] = "development"

    assert EnvironmentManager.current == "development"
    assert EnvironmentManager.development?
    assert !EnvironmentManager.production?
  end

  it "detects production environment" do
    ENV["AZU_ENV"] = "production"

    assert EnvironmentManager.current == "production"
    assert EnvironmentManager.production?
    assert !EnvironmentManager.development?
  end

  it "defaults to development when no environment set" do
    ENV.delete("AZU_ENV")
    ENV.delete("CRYSTAL_ENV")

    assert EnvironmentManager.current == "development"
  end
end

describe "FeatureFlags" do
  before_each do
    ENV["AZU_ENV"] = "development"
    FeatureFlags.load_from_env
  end

  it "enables debug mode in development" do
    assert FeatureFlags.enabled?("debug_mode")
  end

  it "disables debug mode in production" do
    ENV["AZU_ENV"] = "production"
    FeatureFlags.load_from_env

    assert !FeatureFlags.enabled?("debug_mode")
  end

  it "loads feature flags from environment variables" do
    ENV["FEATURE_NEW_UI"] = "true"
    FeatureFlags.load_from_env

    assert FeatureFlags.enabled?("new_ui")
  end
end

describe "Configuration" do
  it "uses environment-specific database URLs" do
    ENV["AZU_ENV"] = "development"
    config = DatabaseConfig.new

    assert config.url.includes?("dev.db")
  end

  it "requires SSL in production" do
    ENV["AZU_ENV"] = "production"
    config = DatabaseConfig.new

    assert config.ssl_mode == "require"
  end
end
```

## Best Practices

### 1. Use Environment Variables for Configuration

```crystal
# Good: Environment-based configuration
class Config
  DATABASE_URL = ENV["DATABASE_URL"]? || "sqlite://./dev.db"
  SECRET_KEY = ENV["SECRET_KEY"]? || raise "SECRET_KEY required"
end

# Avoid: Hardcoded configuration
class Config
  DATABASE_URL = "postgresql://user:pass@localhost/db"
  SECRET_KEY = "hardcoded-secret"
end
```

### 2. Validate Required Environment Variables

```crystal
# Good: Validate required variables
def self.validate_environment!
  required_vars = ["DATABASE_URL", "SECRET_KEY"]
  missing = required_vars.select { |var| ENV[var]?.nil? }

  unless missing.empty?
    raise "Missing required environment variables: #{missing.join(", ")}"
  end
end

# Avoid: No validation
def self.start
  # Start without checking required variables
end
```

### 3. Use Feature Flags for Gradual Rollouts

```crystal
# Good: Feature flag usage
def process_request
  if FeatureFlags.enabled?("new_algorithm")
    new_algorithm
  else
    old_algorithm
  end
end

# Avoid: Environment-based feature switching
def process_request
  if EnvironmentManager.development?
    new_algorithm
  else
    old_algorithm
  end
end
```

### 4. Configure Logging Per Environment

```crystal
# Good: Environment-specific logging
def self.configure_logging
  case EnvironmentManager.current
  when EnvironmentManager::DEVELOPMENT
    Log.setup("*", :debug)
  when EnvironmentManager::PRODUCTION
    Log.setup("*", :warn)
  end
end

# Avoid: Same logging for all environments
def self.configure_logging
  Log.setup("*", :info)  # Same for all environments
end
```

## Next Steps

- [Performance Tuning](advanced/performance-tuning.md) - Optimize performance per environment
- [File Uploads](advanced/file-uploads.md) - Configure upload settings per environment
- [Content Negotiation](advanced/content-negotiation.md) - Environment-specific content handling
- [API Reference](api-reference.md) - Explore environment management APIs

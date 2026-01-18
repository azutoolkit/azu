require "../src/azu"
require "sqlite3"
require "db"

module ExampleApp
  include Azu

  configure do
    templates.path = "playground/templates"
    # Enable hot reload for development and specs/pipeline testing
    # This allows template changes to be picked up automatically during testing
    _ = true
    cache_config.enabled = true
    cache_config.store = "memory"
    cache_config.max_size = 1000
    cache_config.default_ttl = 300
    cache_config.redis_url = "redis://localhost:6379"
    cache_config.redis_timeout = 5
    cache_config.redis_pool_size = 10

    # Only create performance monitor when monitoring is enabled
    {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
      performance_monitor = Handler::PerformanceMonitor.new
    {% end %}
  end
end

require "./requests/*"
require "./responses/*"
require "./endpoints/*"
require "./channels/*"

# Initialize in-memory SQLite database for real database query testing
ExampleApp.init_database
puts "Database initialized with test data"

# Build handler chain with explicit typing to avoid Crystal type inference issues
{% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
  ExampleApp.start [
    Azu::Handler::RequestId.new,                     # Enhanced request ID tracking
    Azu::Handler::DevDashboard.new,                  # Development Dashboard at /dev-dashboard
    ExampleApp::CONFIG.performance_monitor.not_nil!, # Performance metrics collection (shared instance)
    Azu::Handler::Rescuer.new,                       # Enhanced error handling
    Azu::Handler::Logger.new,                        # Request logging
  ]
{% else %}
  ExampleApp.start [
    Azu::Handler::RequestId.new, # Enhanced request ID tracking
    Azu::Handler::Rescuer.new,   # Enhanced error handling
    Azu::Handler::Logger.new,    # Request logging
  ]
{% end %}

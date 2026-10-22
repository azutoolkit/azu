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

# Copy for the layout and pages lives in playground/locales/en.yml and is used through t().
Azu::Helpers::I18n.configure do |config|
  config.load_path = ["playground/locales"]
  config.default_locale = "en"
end

require "./requests/*"
require "./responses/*"
require "./handlers/*"
require "./endpoints/*"
require "./channels/*"

# Initialize in-memory SQLite database for real database query testing
ExampleApp.init_database
puts "Database initialized with test data"

# Forms are CSRF-protected. The synchronizer strategy keeps one token per browser, so several
# open tabs keep working. The JSON API routes below are called by scripts and skip the check.
Azu::Handler::CSRF.use_synchronizer_token!
csrf = Azu::Handler::CSRF.new(
  skip_routes: ["/json/", "/counter/", "/cache/clear", "/cache/delete", "/error-demo"],
  strategy: Azu::Handler::CSRF::Strategy::SynchronizerToken,
  secure_cookies: false
)

# Build handler chain with explicit typing to avoid Crystal type inference issues
{% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
  ExampleApp.start [
    Azu::Handler::RequestId.new,                                      # Enhanced request ID tracking
    Azu::Handler::DevDashboard.new,                                   # Development Dashboard at /dev-dashboard
    ExampleApp::CONFIG.performance_monitor.not_nil!,                  # Performance metrics collection (shared instance)
    Azu::Handler::Static.new("playground/public", fallthrough: true), # CSS and JS for the pages
    Azu::Handler::Rescuer.new,                                        # Enhanced error handling
    Azu::Handler::Logger.new,                                         # Request logging
    ExampleApp::CsrfSeed.new,                                         # One CSRF token per first-time visitor
    csrf,                                                             # CSRF protection for form posts
    ExampleApp::PageErrors.new,                                       # Friendly HTML error pages
  ]
{% else %}
  ExampleApp.start [
    Azu::Handler::RequestId.new,                                      # Enhanced request ID tracking
    Azu::Handler::Static.new("playground/public", fallthrough: true), # CSS and JS for the pages
    Azu::Handler::Rescuer.new,                                        # Enhanced error handling
    Azu::Handler::Logger.new,                                         # Request logging
    ExampleApp::CsrfSeed.new,                                         # One CSRF token per first-time visitor
    csrf,                                                             # CSRF protection for form posts
    ExampleApp::PageErrors.new,                                       # Friendly HTML error pages
  ]
{% end %}

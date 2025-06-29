require "../src/azu"

module ExampleApp
  include Azu

  configure do
    templates.path = "playground/templates"
    # Enable hot reload for development and specs/pipeline testing
    # This allows template changes to be picked up automatically during testing
    template_hot_reload = true
    cache_config.enabled = true
    cache_config.store = "memory"
    cache_config.max_size = 1000
    cache_config.default_ttl = 300
    cache_config.redis_url = "redis://localhost:6379"
    cache_config.redis_timeout = 5
    cache_config.redis_pool_size = 10
    performance_monitor = Handler::PerformanceMonitor.new
  end
end

require "./requests/*"
require "./responses/*"
require "./endpoints/*"
require "./channels/*"

ExampleApp.start [
  Azu::Handler::RequestId.new,                     # Enhanced request ID tracking
  ExampleApp::CONFIG.performance_monitor.not_nil!, # Performance metrics collection (shared instance)
  Azu::Handler::Rescuer.new,                       # Enhanced error handling
  Azu::Handler::Logger.new,                        # Request logging
]

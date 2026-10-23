# Development and diagnostics: the dev dashboard (`Handler::DevDashboard`), request, cache and component
# metrics (`Handler::PerformanceMonitor`, `PerformanceMetrics`, `PerformanceReporter`), and the profiler and
# memory leak detector (`DevelopmentTools`).
#
# Opt in with `require "azu/dev"` after `require "azu"`. Core only exposes `Azu::Instrumentation`; this
# file plugs the metrics and the profiler into it.
require "../../azu"
require "./configuration"
require "./performance_reporter"
require "./dev_dashboard_component"
require "./dev_dashboard"

module Azu
  module Dev
    # Whether the configuration the code runs under has request monitoring on.
    def self.monitoring? : Bool
      Azu.current_config.performance_enabled?
    end

    # Metrics of the configuration the code runs under, when it has request monitoring on.
    def self.metrics : PerformanceMetrics?
      config = Azu.current_config
      config.performance_monitor.try(&.metrics) if config.performance_enabled?
    end
  end

  Instrumentation.on_cache(-> { Dev.monitoring? }) do |op|
    Dev.metrics.try do |metrics|
      metrics.record_cache(op.key, op.operation, op.store, op.duration_ms, op.hit, op.key_size, op.value_size, op.ttl, op.error)
    end
  end

  Instrumentation.on_component(-> { Dev.monitoring? }) do |event|
    Dev.metrics.try do |metrics|
      metrics.record_component(event.id, event.type, event.event, event.duration_ms, event.memory_before, event.memory_after, event.age)
    end
  end

  Instrumentation.on_prepare do |config|
    config.development_tools.profiler.enabled = true if config.performance_profiling_enabled?
    if config.performance_memory_monitoring?
      config.development_tools.memory_detector.start_monitoring
      config.memory_monitor_started = true
    end
  end

  Instrumentation.on_finalize do |config|
    config.development_tools.memory_detector.stop_monitoring if config.memory_monitor_started?
  end
end

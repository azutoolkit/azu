module Azu
  module Spark
    # Feeds component lifecycle timings (`mount`, `unmount`, `refresh`, `event_handler:<name>`)
    # to the performance monitor and dev dashboard. Compiles to a plain `yield` unless
    # performance monitoring is enabled at build time.
    module Instrumentation
      def self.measure(entry : Entry, event : String, &)
        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          return yield unless Azu::CONFIG.performance_enabled? && (monitor = Azu::CONFIG.performance_monitor)

          started = Time.instant
          memory_before = Azu::PerformanceMetrics.current_memory_usage
          result = yield
          monitor.metrics.record_component(
            component_id: entry.id,
            component_type: entry.component.class.name,
            event: event,
            processing_time: (Time.instant - started).total_milliseconds,
            memory_before: memory_before,
            memory_after: Azu::PerformanceMetrics.current_memory_usage,
            age_at_event: entry.age
          )
          result
        {% else %}
          yield
        {% end %}
      end
    end
  end
end

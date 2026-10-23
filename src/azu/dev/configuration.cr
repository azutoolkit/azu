require "../../azu"
require "./development_tools"
require "./performance_monitor"

module Azu
  class Configuration
    # Request monitoring, cache and component metrics. Off unless `PERFORMANCE_MONITORING=true`.
    property? performance_enabled : Bool = ENV.fetch("PERFORMANCE_MONITORING", "false") == "true"
    # The profiler and memory monitor follow `PERFORMANCE_PROFILING` / `PERFORMANCE_MEMORY_MONITORING`,
    # and are on in development when the variable is not set.
    @performance_profiling_enabled : Bool? = ENV["PERFORMANCE_PROFILING"]?.presence.try(&.== "true")
    @performance_memory_monitoring : Bool? = ENV["PERFORMANCE_MEMORY_MONITORING"]?.presence.try(&.== "true")
    setter performance_profiling_enabled : Bool?
    setter performance_memory_monitoring : Bool?

    def performance_profiling_enabled? : Bool
      @performance_profiling_enabled.nil? ? env.development? : @performance_profiling_enabled == true
    end

    def performance_memory_monitoring? : Bool
      @performance_memory_monitoring.nil? ? env.development? : @performance_memory_monitoring == true
    end

    # The memory monitor is process-wide: it is stopped only by the configuration that started it, not
    # when some other configuration (a second app, a spec) is collected.
    property? memory_monitor_started : Bool = false

    @performance_monitor : Handler::PerformanceMonitor? = nil

    # Shares the instance held by the handler chain.
    setter performance_monitor : Handler::PerformanceMonitor?

    # The monitor is only created once `performance_enabled?` is on.
    def performance_monitor : Handler::PerformanceMonitor?
      @performance_monitor || (performance_enabled? ? (@performance_monitor = Handler::PerformanceMonitor.new) : nil)
    end

    def development_tools
      DevelopmentTools
    end
  end
end

require "./markup"
require "uuid"
require "http/web_socket"

# Conditionally require performance metrics only when enabled
{% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
  require "./performance_metrics"
{% end %}

module Azu
  module Component
    include Markup
    property? mounted = false
    property? connected = false
    getter id : String = UUID.random.to_s

    @socket : HTTP::WebSocket? = nil
    @created_at = Time.utc
    @performance_tracking_enabled = false

    getter socket

    macro included
      def self.mount(**args)
        component = new **args
        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          # Performance tracking only when enabled
          start_time = Time.instant
          memory_before = nil
          if component.@performance_tracking_enabled
            memory_before = Azu::PerformanceMetrics.current_memory_usage
          end
        {% end %}

        component.mounted = true
        Azu::Spark.components.register(component.id, component)

        {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
          # Track component mount performance only when enabled
          if component.@performance_tracking_enabled && Azu::CONFIG.performance_enabled?
            end_time = Time.instant
            memory_after = Azu::PerformanceMetrics.current_memory_usage
            processing_time = (end_time - start_time).total_milliseconds

            if monitor = Azu::CONFIG.performance_monitor
              monitor.metrics.record_component(
                component_id: component.id,
                component_type: component.class.name,
                event: "mount",
                processing_time: processing_time,
                memory_before: memory_before,
                memory_after: memory_after,
                age_at_event: component.age
              )
            end
          end
        {% end %}

        component
      end
    end

    def disconnected?
      !connected?
    end

    def age
      Time.utc - @created_at
    end

    def mount
      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        start_time = Time.instant
        memory_before = nil
        if @performance_tracking_enabled
          memory_before = Azu::PerformanceMetrics.current_memory_usage
        end
      {% end %}

      @mounted = true

      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        # Track mount performance only when enabled
        if @performance_tracking_enabled && Azu::CONFIG.performance_enabled?
          end_time = Time.instant
          memory_after = Azu::PerformanceMetrics.current_memory_usage
          processing_time = (end_time - start_time).total_milliseconds

          if monitor = Azu::CONFIG.performance_monitor
            monitor.metrics.record_component(
              component_id: @id,
              component_type: self.class.name,
              event: "mount",
              processing_time: processing_time,
              memory_before: memory_before,
              memory_after: memory_after,
              age_at_event: age
            )
          end
        end
      {% end %}
    end

    def unmount
      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        start_time = Time.instant
        memory_before = nil
        if @performance_tracking_enabled
          memory_before = Azu::PerformanceMetrics.current_memory_usage
        end
      {% end %}

      @mounted = false

      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        # Track unmount performance only when enabled
        if @performance_tracking_enabled && Azu::CONFIG.performance_enabled?
          end_time = Time.instant
          memory_after = Azu::PerformanceMetrics.current_memory_usage
          processing_time = (end_time - start_time).total_milliseconds

          if monitor = Azu::CONFIG.performance_monitor
            monitor.metrics.record_component(
              component_id: @id,
              component_type: self.class.name,
              event: "unmount",
              processing_time: processing_time,
              memory_before: memory_before,
              memory_after: memory_after,
              age_at_event: age
            )
          end
        end
      {% end %}
    end

    def on_event(name, data)
      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        start_time = Time.instant
        memory_before = nil
        if @performance_tracking_enabled
          memory_before = Azu::PerformanceMetrics.current_memory_usage
        end
      {% end %}

      # Default implementation - override in subclasses

      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        # Track event handling performance only when enabled
        if @performance_tracking_enabled && Azu::CONFIG.performance_enabled?
          end_time = Time.instant
          memory_after = Azu::PerformanceMetrics.current_memory_usage
          processing_time = (end_time - start_time).total_milliseconds

          if monitor = Azu::CONFIG.performance_monitor
            monitor.metrics.record_component(
              component_id: @id,
              component_type: self.class.name,
              event: "event_handler:#{name}",
              processing_time: processing_time,
              memory_before: memory_before,
              memory_after: memory_after,
              age_at_event: age
            )
          end
        end
      {% end %}
    end

    def content
    end

    def refresh
      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        start_time = Time.instant
        memory_before = nil
        if @performance_tracking_enabled
          memory_before = Azu::PerformanceMetrics.current_memory_usage
        end
      {% end %}

      content
      if socket = @socket
        json = {content: to_s, id: id}.to_json
        socket.send json
        # Only clear the view after sending to socket
        @view = IO::Memory.new
      end
      # Don't clear the view if there's no socket, so content remains available

      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        # Track refresh performance only when enabled
        if @performance_tracking_enabled && Azu::CONFIG.performance_enabled?
          end_time = Time.instant
          memory_after = Azu::PerformanceMetrics.current_memory_usage
          processing_time = (end_time - start_time).total_milliseconds

          if monitor = Azu::CONFIG.performance_monitor
            monitor.metrics.record_component(
              component_id: @id,
              component_type: self.class.name,
              event: "refresh",
              processing_time: processing_time,
              memory_before: memory_before,
              memory_after: memory_after,
              age_at_event: age
            )
          end
        end
      {% end %}
    end

    def refresh(&)
      yield
      refresh
    end

    def every(duration : Time::Span, &block)
      spawn do
        while connected?
          sleep duration
          block.call if connected?
        end
      rescue IO::Error
        # This happens when a socket closes at just the right time
      rescue ex
        ex.inspect STDERR
      end
    end

    def socket=(other)
      @socket = other
    end

    def render
      content
      <<-HTML
      <div data-spark-view="#{id}">
        <div>#{to_s}</div>
      </div>
      HTML

    ensure
      @view = IO::Memory.new
    end

    # Component pooling methods for memory optimization
    def reset_for_reuse
      @mounted = false
      @connected = false
      @socket = nil
      @created_at = Time.utc
      @view = IO::Memory.new
      generate_new_id
    end

    def prepare_for_pool
      unmount
      @socket = nil
      @connected = false
      # Clear any component-specific state that shouldn't persist
      @view = IO::Memory.new
    end

    # Enable performance tracking for this component
    def enable_performance_tracking
      {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
        @performance_tracking_enabled = true
      {% end %}
    end

    # Disable performance tracking for this component
    def disable_performance_tracking
      @performance_tracking_enabled = false
    end

    private def generate_new_id
      @id = UUID.random.to_s
    end
  end
end

require "./markup"
require "./performance_metrics"
require "uuid"
require "http/web_socket"

module Azu
  module Component
    include Markup
    property? mounted = false
    property? connected = false
    getter id : String = UUID.random.to_s

    @socket : HTTP::WebSocket? = nil
    @created_at = Time.utc
    @performance_tracking_enabled = true

    getter socket

    macro included
      def self.mount(**args)
        component = new **args
        start_time = Time.monotonic
        memory_before = Azu::PerformanceMetrics.current_memory_usage if component.@performance_tracking_enabled

        component.mounted = true
        Azu::Spark.components.register(component.id, component)

        # Track component mount performance
        if component.@performance_tracking_enabled
          end_time = Time.monotonic
          memory_after = Azu::PerformanceMetrics.current_memory_usage
          processing_time = (end_time - start_time).total_milliseconds

          Azu::CONFIG.performance_monitor.try &.metrics.record_component(
            component_id: component.id,
            component_type: component.class.name,
            event: "mount",
            processing_time: processing_time,
            memory_before: memory_before,
            memory_after: memory_after,
            age_at_event: component.age
          )
        end

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
      start_time = Time.monotonic
      memory_before = Azu::PerformanceMetrics.current_memory_usage if @performance_tracking_enabled

      @mounted = true

      # Track mount performance
      if @performance_tracking_enabled
        end_time = Time.monotonic
        memory_after = Azu::PerformanceMetrics.current_memory_usage
        processing_time = (end_time - start_time).total_milliseconds

        Azu::CONFIG.performance_monitor.try &.metrics.record_component(
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

    def unmount
      start_time = Time.monotonic
      memory_before = Azu::PerformanceMetrics.current_memory_usage if @performance_tracking_enabled

      # Track unmount performance
      if @performance_tracking_enabled
        end_time = Time.monotonic
        memory_after = Azu::PerformanceMetrics.current_memory_usage
        processing_time = (end_time - start_time).total_milliseconds

        Azu::CONFIG.performance_monitor.try &.metrics.record_component(
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

    def on_event(name, data)
      start_time = Time.monotonic
      memory_before = Azu::PerformanceMetrics.current_memory_usage if @performance_tracking_enabled

      # Default implementation - override in subclasses

      # Track event handling performance
      if @performance_tracking_enabled
        end_time = Time.monotonic
        memory_after = PerformanceMetrics.current_memory_usage
        processing_time = (end_time - start_time).total_milliseconds

        Azu::CONFIG.performance_monitor.try &.metrics.record_component(
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

    def content
    end

    def refresh
      start_time = Time.monotonic
      memory_before = PerformanceMetrics.current_memory_usage if @performance_tracking_enabled

      content
      if socket = @socket
        json = {content: to_s, id: id}.to_json
        socket.send json
        # Only clear the view after sending to socket
        @view = IO::Memory.new
      end
      # Don't clear the view if there's no socket, so content remains available

      # Track refresh performance
      if @performance_tracking_enabled
        end_time = Time.monotonic
        memory_after = PerformanceMetrics.current_memory_usage
        processing_time = (end_time - start_time).total_milliseconds

        Azu::CONFIG.performance_monitor.try &.metrics.record_component(
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

    private def generate_new_id
      @id = UUID.random.to_s
    end
  end
end

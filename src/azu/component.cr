require "./markup"
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

    getter socket

    macro included
      def self.mount(**args)
        component = new **args
        component.mounted = true
        Azu::Spark.components.register(component.id, component)
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
      @mounted = true
    end

    def unmount
    end

    def on_event(name, data)
    end

    def content
    end

    def refresh
      content
      if socket = @socket
        json = {content: to_s, id: id}.to_json
        socket.send json
        # Only clear the view after sending to socket
        @view = IO::Memory.new
      end
      # Don't clear the view if there's no socket, so content remains available
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

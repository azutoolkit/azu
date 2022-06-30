require "./markup"

module Azu
  module Component
    include Markup

    property? connected = false
    getter id : String = UUID.random.to_s
    getter? mounted = false
    @socket : HTTP::WebSocket? = nil
    @created_at = Time.utc

    macro included
      def self.mount(**args)
        @mounted = true
        component = new **args
        Azu::Spark::COMPONENTS[component.id] = component
        component.render
      end
    end

    def dicconnected?
      !connected?
    end

    def age
      Time.utc - @created_at
    end

    def mount
    end

    def unmount
    end

    def on_event(name, data)
    end

    def content
    end

    def refresh
      content
      json = {content: to_s, id: id}.to_json
      @socket.not_nil!.send json
    ensure
      @view = IO::Memory.new
    end

    def refresh
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
  end
end

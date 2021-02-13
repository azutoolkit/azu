require "./markup"

module Azu
  module Component
    include Markup

    property? connected = false
    getter id : String = UUID.random.to_s
    @socket : HTTP::WebSocket? = nil

    macro included
      def self.mount(**args)
        component = new **args
        Azu::Spark::COMPONENTS[component.id] = component
        component.render
      end
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
      end
    end

    def socket=(other)
      @socket = other
    end

    def render
      content
      <<-HTML
      <div data-live-view="#{id}">
        <div>#{to_s}</div>
      </div>
      HTML

    ensure
      @view = IO::Memory.new
    end
  end
end

require "uuid"

module Azu
  class Spark < Channel
    def self.javascript_tags
      <<-HTML
        <script src="https://unpkg.com/preact@8.4.2/dist/preact.min.js""></script>
        <script src="https://unpkg.com/preact-html-converter@0.4.2/dist/preact-html-converter.browser.js"></script>
        <script src="/assets/js/data.js"></script>
      HTML
    end

    COMPONENTS = {} of String => SparkView

    def on_binary(binary); end

    def on_ping(message); end

    def on_pong(message); end

    def on_connect
    end

    def on_close(code, message)
      COMPONENTS.each do |id, component|
        component.unmount
        COMPONENTS.delete id
      end
    end

    def on_message(message : String)
      json = JSON.parse(message)

      if channel = json["subscribe"]?
        spark = channel.to_s
        COMPONENTS[spark].connected = true
        COMPONENTS[spark].socket = socket
        COMPONENTS[spark].mount
      elsif event_name = json["event"]?
        spark = json["channel"].not_nil!
        data = json["data"].not_nil!
        COMPONENTS[spark].on_event(event_name.not_nil!, data)
      end
    end
  end

  class SparkView
    property? connected = false
    getter spark_id : String = UUID.random.to_s
    @socket = uninitialized HTTP::WebSocket

    def initialize
      Spark::COMPONENTS[spark_id] = self
    end

    # Start: Live View API
    def mount
    end

    def unmount
    end

    def on_event(name, data)
    end

    def render(io)
    end

    def refresh(buffer = IO::Memory.new)
      render buffer
      json = {
        render: buffer.to_s,
        id:     spark_id,
      }.to_json

      @socket.not_nil!.send json
    end

    def refresh(buffer = IO::Memory.new)
      yield
      refresh buffer
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

    def to_s(io)
      io << %{<div data-live-view="#{spark_id}"><div>}
      render io
      io << %{</div></div>}
    end
  end
end

require "uuid"

module Azu
  class Spark < Channel
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
    rescue ex : IO::Error
      puts "Socket closed"
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

    def component
    end

    def refresh
      json = {content: to_s, id: spark_id}.to_json
      @socket.not_nil!.send json
    end

    def refresh
      yield
      refresh component
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

    def to_s
      String.build do |str|
        str << %{<div data-live-view="#{spark_id}"><div>}
        str << component
        str << %{</div></div>}
      end
    end
  end
end

require "uuid"

module Azu
  class Spark < Channel
    COMPONENTS = {} of String => Component

    def on_binary(binary); end

    def on_ping(message); end

    def on_pong(message); end

    def on_connect
    end

    def on_close(code : ::CloseCode | Int | ::Nil = nil, message = nil)
      COMPONENTS.each do |id, component|
        component.unmount
        COMPONENTS.delete id
      end
    end

    def on_message(message)
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
end

require "uuid"

module Azu
  class Spark < Channel
    COMPONENTS  = {} of String => Component
    GC_INTERVAL = 10.seconds

    gc_sweep

    def self.javascript_tag
      <<-JS

      JS
    end

    private def self.gc_sweep
      spawn do
        loop do
          sleep GC_INTERVAL
          COMPONENTS.reject! do |key, component|
            component.dicconnected? && (
              component.mounted? || component.age > GC_INTERVAL
            )
          end
        end
      end
    end

    def on_binary(binary); end

    def on_ping(message); end

    def on_pong(message); end

    def on_connect
    end

    def on_close(code : HTTP::WebSocket::CloseCode | Int? = nil, message = nil)
      COMPONENTS.each do |id, component|
        component.unmount
        COMPONENTS.delete id
      rescue KeyError
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
        data = json["data"].not_nil!.as_s
        COMPONENTS[spark].on_event(event_name.as_s, data)
      end
    rescue IO::Error
    rescue ex
      ex.inspect STDERR
    end
  end
end

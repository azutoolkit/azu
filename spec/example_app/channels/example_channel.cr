module ExampleApp
  # Websockets Channels
  class ExampleChannel < Azu::Channel
    SUBSCRIBERS = [] of HTTP::WebSocket

    def on_connect
      SUBSCRIBERS << socket.not_nil!
      @socket.not_nil!.send SUBSCRIBERS.size.to_s
    end

    def on_binary(binary)
    end

    def on_pong(message)
    end

    def on_ping(message)
    end

    def on_message(message)
      SUBSCRIBERS.each { |s| s.send "Polo!" }
    end

    def on_close(code : CloseCode | Int | ::Nil = nil, message = nil)
      SUBSCRIBERS.delete socket
    end
  end
end

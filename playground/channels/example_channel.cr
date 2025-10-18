module ExampleApp
  # Websockets Channels
  class ExampleChannel < Azu::Channel
    SUBSCRIBERS = [] of HTTP::WebSocket

    ws "/hi"

    def on_connect
      SUBSCRIBERS << socket if socket
      @socket.try(&.send(SUBSCRIBERS.size.to_s))
    end

    def on_binary(binary)
    end

    def on_pong(message)
    end

    def on_ping(message)
    end

    def on_message(message)
      SUBSCRIBERS.each(&.send("Polo!"))
    end

    def on_close(code : HTTP::WebSocket::CloseCode | Int? = nil, message = nil)
      SUBSCRIBERS.delete socket
    end
  end
end

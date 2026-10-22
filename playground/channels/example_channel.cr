module ExampleApp
  # A tiny presence channel. Clients receive JSON:
  #   {"type":"presence","subscribers":2}  when someone joins or leaves
  #   {"type":"polo","subscribers":2}      when anyone sends a message ("Marco!")
  class ExampleChannel < Azu::Channel
    SUBSCRIBERS = [] of HTTP::WebSocket
    LOCK        = Mutex.new

    ws "/hi"

    def self.online : Int32
      LOCK.synchronize { SUBSCRIBERS.size }
    end

    def on_connect
      sock = socket
      LOCK.synchronize { SUBSCRIBERS << sock }
      announce("presence")
    end

    def on_binary(binary)
    end

    def on_pong(message)
    end

    def on_ping(message)
    end

    def on_message(message)
      announce("polo")
    end

    def on_close(code : HTTP::WebSocket::CloseCode | Int? = nil, message = nil)
      sock = socket
      LOCK.synchronize { SUBSCRIBERS.delete sock }
      announce("presence")
    end

    private def announce(type : String) : Nil
      sockets = LOCK.synchronize { SUBSCRIBERS.dup }
      payload = {type: type, subscribers: sockets.size}.to_json
      sockets.each do |sock|
        sock.send(payload)
      rescue IO::Error
        # A peer that vanished is cleaned up by its own on_close.
      end
    end
  end
end

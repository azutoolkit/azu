require "http/server"
require "http/web_socket"

# Runs the block with `Azu::CONFIG.env` switched to *env*.
def with_spark_env(env : Azu::Environment, &)
  previous = Azu::CONFIG.env
  Azu::CONFIG.env = env
  yield
ensure
  Azu::CONFIG.env = previous if previous
end

# Serves *handler* on a free local port while the block runs.
def with_ws_server(handler : HTTP::Handler, &)
  server = HTTP::Server.new([handler]) { |context| context.response.respond_with_status(:not_found) }
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  yield address.port
ensure
  server.try(&.close)
end

# A real WebSocket client that collects the server's text frames.
class WsProbe
  getter close_code : HTTP::WebSocket::CloseCode? = nil

  def initialize(port : Int32, path : String = "/", origin : String? = nil)
    headers = HTTP::Headers.new
    headers["Origin"] = origin if origin
    @messages = ::Channel(String).new(256)
    @socket = HTTP::WebSocket.new("127.0.0.1", path, port, headers: headers)
    @socket.on_message { |message| @messages.send(message) }
    @socket.on_close do |code, _|
      @close_code = code
      @messages.close
    end
    spawn do
      @socket.run
    rescue IO::Error
      # The server dropped the connection while the close handshake was in flight.
    end
  end

  def send(message : String) : Nil
    @socket.send(message)
  end

  # Next text frame, or nil when the server closed the socket or *timeout* elapsed.
  def receive(timeout : Time::Span = 2.seconds) : String?
    select
    when message = @messages.receive?
      message
    when timeout(timeout)
      nil
    end
  end

  def closed? : Bool
    @messages.closed?
  end

  def close : Nil
    @socket.close
  end
end

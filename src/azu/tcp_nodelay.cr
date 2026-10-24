require "socket"

module Azu
  # Nagle's algorithm holds a small write back until the previous one is acknowledged. A Spark event
  # is answered by two small writes (the diff, then the reply), and a peer that delays its ACK (a
  # Linux client does, by about 40 ms) makes every round trip wait for it: 44 ms against 0.28 ms on
  # loopback. Request and response WebSocket traffic wants every frame on the wire at once, so the
  # sockets of upgraded connections get `TCP_NODELAY` (`WebSocketConfiguration#tcp_nodelay`).
  module TCPNoDelay
    # Sets `TCP_NODELAY` on *io* when it is a TCP socket; any other IO (a unix socket, an in-memory
    # IO in a spec, a TLS socket whose transport is out of reach) is left as it is. A socket the peer
    # has already closed is not an error either: the connection ends on its own.
    def self.apply(io : IO, enabled : Bool = true) : Nil
      return unless enabled
      return unless io.is_a?(TCPSocket)
      io.tcp_nodelay = true
    rescue IO::Error | Socket::Error
    end
  end

  # A `TCPServer` whose accepted sockets have `TCP_NODELAY` set. A TLS server wraps the sockets it
  # accepts, which hides the TCP socket from the upgrade, so `Azu.start` builds its TLS listener on
  # this class when the option is on.
  class NoDelayTCPServer < TCPServer
    def accept? : TCPSocket?
      super.try do |socket|
        TCPNoDelay.apply(socket)
        socket
      end
    end
  end

  # Binds *server* to a TLS listener like `HTTP::Server#bind_tls`; with *nodelay* the sockets
  # underneath have `TCP_NODELAY` set.
  def self.bind_tls(server : HTTP::Server, host : String, port : Int32, context : OpenSSL::SSL::Context::Server, reuse_port : Bool, nodelay : Bool) : Socket::IPAddress
    return server.bind_tls(host, port, context, reuse_port) unless nodelay
    tcp_server = NoDelayTCPServer.new(host, port, reuse_port: reuse_port)
    begin
      listener = OpenSSL::SSL::Server.new(tcp_server, context)
      listener.start_immediately = false
      server.bind(listener)
    rescue ex
      tcp_server.close
      raise ex
    end
    tcp_server.local_address
  end
end

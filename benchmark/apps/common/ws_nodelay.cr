require "./bench"

# TCP_NODELAY on upgraded (WebSocket) sockets only, never on plain HTTP connections. Crystal sockets leave Nagle on,
# which stalls small WebSocket frames by about 40 ms (delayed ACK). Azu does this itself for upgraded sockets
# (`config.websocket.tcp_nodelay`); the baseline and Kemal use HTTP::Server's upgrade, so this wraps it the same way.
# Only the baseline and Kemal require this file: the Azu app must not (its own setting is what is measured).
# BENCH_WS_NODELAY=0 turns it off for every app (Azu then gets tcp_nodelay = false).
class HTTP::Server::Response
  def upgrade(&block : IO ->) : Nil
    previous_def do |io|
      io.as?(TCPSocket).try(&.tcp_nodelay = true) if Bench.nodelay?
      block.call(io)
    end
  end
end

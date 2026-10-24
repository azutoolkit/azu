require "../spec_helper"
require "../support/spark_helpers"

# Reads the accepted socket back from the upgraded response (the spec looks at what the server holds).
class NoDelayProbeChannel < Azu::Channel
  class_getter seen = ::Channel(Bool?).new(4)

  def on_connect
    socket = context.response.@io
    NoDelayProbeChannel.seen.send(socket.is_a?(TCPSocket) ? socket.tcp_nodelay? : nil)
  end

  def on_message(message : String)
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end
end

private def nodelay_after_upgrade : Bool?
  with_ws_server(Azu::Channel::Upgrader.new(NoDelayProbeChannel)) do |port|
    WsProbe.new(port)
    select
    when seen = NoDelayProbeChannel.seen.receive
      return seen
    when timeout(5.seconds)
      raise "the channel never connected"
    end
  end
end

describe "TCP_NODELAY on WebSocket sockets" do
  around_each do |example|
    saved = Azu::CONFIG.websocket.tcp_nodelay?
    example.run
  ensure
    Azu::CONFIG.websocket.tcp_nodelay = saved.nil? ? true : saved
  end

  it "is on by default" do
    Azu::WebSocketConfiguration.new.tcp_nodelay?.should be_true
  end

  it "is set on the accepted socket when the connection is upgraded" do
    Azu::CONFIG.websocket.tcp_nodelay = true
    nodelay_after_upgrade.should be_true
  end

  it "is left alone when the option is off" do
    Azu::CONFIG.websocket.tcp_nodelay = false
    nodelay_after_upgrade.should be_false
  end

  it "does not touch the sockets of plain HTTP requests" do
    seen = nil
    server = HTTP::Server.new([Azu::Channel::Upgrader.new(NoDelayProbeChannel)]) do |context|
      socket = context.response.@io
      seen = socket.is_a?(TCPSocket) ? socket.tcp_nodelay? : nil
      context.response.print "ok"
    end
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield
    begin
      HTTP::Client.get("http://127.0.0.1:#{address.port}/").body.should eq "ok"
      seen.should be_false
    ensure
      server.close
    end
  end

  it "does nothing for an IO that is not a TCP socket" do
    Azu::TCPNoDelay.apply(IO::Memory.new, true)
    left, right = UNIXSocket.pair
    Azu::TCPNoDelay.apply(left, true)
    left.close
    right.close
  end

  it "does not fail when the socket is already gone" do
    server = TCPServer.new("127.0.0.1", 0)
    client = TCPSocket.new("127.0.0.1", server.local_address.port)
    accepted = server.accept
    accepted.close
    Azu::TCPNoDelay.apply(accepted, true)
    client.close
    server.close
  end
end

describe Azu::NoDelayTCPServer do
  it "sets TCP_NODELAY on every socket it accepts" do
    server = Azu::NoDelayTCPServer.new("127.0.0.1", 0)
    client = TCPSocket.new("127.0.0.1", server.local_address.port)
    accepted = server.accept
    begin
      accepted.tcp_nodelay?.should be_true
      client.tcp_nodelay?.should be_false
    ensure
      accepted.close
      client.close
      server.close
    end
  end

  it "is what a TLS server accepts through when the option is on" do
    context = OpenSSL::SSL::Context::Server.new
    server = HTTP::Server.new { }
    Azu.bind_tls(server, "127.0.0.1", 0, context, false, true)
    begin
      ssl = server.@sockets.first.as(OpenSSL::SSL::Server)
      ssl.@wrapped.should be_a(Azu::NoDelayTCPServer)
    ensure
      server.close
    end
  end

  it "leaves the TLS listener plain when the option is off" do
    context = OpenSSL::SSL::Context::Server.new
    server = HTTP::Server.new { }
    Azu.bind_tls(server, "127.0.0.1", 0, context, false, false)
    begin
      ssl = server.@sockets.first.as(OpenSSL::SSL::Server)
      ssl.@wrapped.should_not be_a(Azu::NoDelayTCPServer)
    ensure
      server.close
    end
  end
end

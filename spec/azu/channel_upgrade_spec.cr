require "../spec_helper"
require "../support/spark_helpers"

class EchoChannel < Azu::Channel
  class_getter connections = Atomic(Int32).new(0)
  class_getter closed = ::Channel(Nil).new(8)

  def on_connect
    EchoChannel.connections.add(1)
  end

  def on_message(message : String)
    case message
    when "headers"               then send("origin=#{headers["Origin"]?} q=#{params["q"]?}")
    when .starts_with?("sub:")   then subscribe(message.lchop("sub:"))
    when .starts_with?("unsub:") then unsubscribe(message.lchop("unsub:"))
    when .starts_with?("say:")   then broadcast("room", message.lchop("say:"))
    else                              send("echo:#{message}")
    end
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
    EchoChannel.closed.send(nil)
  end
end

class RaisingChannel < EchoChannel
  def on_message(message : String)
    subscribe("doomed")
    raise "boom"
  end
end

# Round trip that proves the server handled everything sent before it.
private def sync(client : WsProbe) : Nil
  client.send("sync")
  client.receive.should eq "echo:sync"
end

class SmallChannel < EchoChannel
  def self.max_message_size : Int32
    64
  end
end

describe Azu::Channel do
  describe ".origin_allowed?" do
    request = ->(origin : String?, host : String?) do
      headers = HTTP::Headers.new
      headers["Origin"] = origin if origin
      headers["Host"] = host if host
      HTTP::Request.new("GET", "/", headers)
    end

    it "accepts the same origin, with or without a port" do
      EchoChannel.origin_allowed?(request.call("http://localhost:4000", "localhost:4000")).should be_true
      EchoChannel.origin_allowed?(request.call("https://example.com", "example.com")).should be_true
    end

    it "rejects a foreign origin and the opaque 'null' origin" do
      EchoChannel.origin_allowed?(request.call("https://evil.example", "example.com")).should be_false
      EchoChannel.origin_allowed?(request.call("null", "example.com")).should be_false
    end

    it "accepts requests without an Origin header (non-browser clients)" do
      EchoChannel.origin_allowed?(request.call(nil, "example.com")).should be_true
    end

    it "honours the allow list" do
      websocket = Azu::CONFIG.websocket
      begin
        websocket.allowed_origins = ["https://app.example.com"]
        EchoChannel.origin_allowed?(request.call("https://app.example.com", "api.example.com")).should be_true
        EchoChannel.origin_allowed?(request.call("https://evil.example", "api.example.com")).should be_false
        websocket.allowed_origins = ["*"]
        EchoChannel.origin_allowed?(request.call("https://evil.example", "api.example.com")).should be_true
      ensure
        websocket.allowed_origins = [] of String
      end
    end
  end

  describe "upgrade over a real socket" do
    it "echoes messages and exposes the upgrade request to the channel" do
      with_ws_server(Azu::Channel::Upgrader.new(EchoChannel)) do |port|
        client = WsProbe.new(port, "/?q=7", origin: "http://127.0.0.1:#{port}")
        client.send("hello")
        client.receive.should eq "echo:hello"
        client.send("headers")
        client.receive.should eq "origin=http://127.0.0.1:#{port} q=7"
        client.close
        EchoChannel.closed.receive
      end
    end

    it "refuses a cross-site origin before upgrading" do
      with_ws_server(Azu::Channel::Upgrader.new(EchoChannel)) do |port|
        expect_raises(Socket::Error, /403/) { WsProbe.new(port, "/", origin: "https://evil.example") }
      end
    end

    it "closes connections sending messages above the size limit" do
      with_ws_server(Azu::Channel::Upgrader.new(SmallChannel)) do |port|
        client = WsProbe.new(port)
        client.send("a" * 10)
        client.receive.should eq "echo:#{"a" * 10}"

        client.send("b" * 4096)

        client.receive.should be_nil
        client.close_code.should eq HTTP::WebSocket::CloseCode::MessageTooBig
        EchoChannel.closed.receive
      end
    end
  end

  describe "broadcasting" do
    after_each { Azu::PubSub.shutdown }

    it "delivers topic broadcasts to every subscribed connection until they unsubscribe or close" do
      with_ws_server(Azu::Channel::Upgrader.new(EchoChannel)) do |port|
        alice = WsProbe.new(port)
        bob = WsProbe.new(port)
        alice.send("sub:room")
        bob.send("sub:room")
        sync(alice)
        sync(bob)

        alice.send("say:hi all")
        alice.receive.should eq "hi all"
        bob.receive.should eq "hi all"

        bob.send("unsub:room")
        sync(bob)
        alice.send("say:again")
        alice.receive.should eq "again"
        bob.receive(200.milliseconds).should be_nil

        alice.close
        EchoChannel.closed.receive
        Azu::PubSub.broadcast("room", "after close")
        bob.close
        EchoChannel.closed.receive
      end
    end
  end

  describe "teardown" do
    after_each { Azu::PubSub.shutdown }

    it "releases subscriptions when on_message raises and ends the connection" do
      backend = Azu::PubSub::Memory.new
      Azu::PubSub.backend = backend
      with_ws_server(Azu::Channel::Upgrader.new(RaisingChannel)) do |port|
        client = WsProbe.new(port)
        client.send("go")
        50.times do
          break if client.closed?
          sleep 20.milliseconds
        end
        sleep 100.milliseconds
        backend.subscriber_count.should eq 0
      end
    end
  end

  describe "heartbeat" do
    it "pings idle connections and stops when the connection closes" do
      previous = Azu::CONFIG.websocket.ping_interval
      Azu::CONFIG.websocket.ping_interval = 30.milliseconds
      begin
        with_ws_server(Azu::Channel::Upgrader.new(EchoChannel)) do |port|
          pings = Atomic(Int32).new(0)
          socket = HTTP::WebSocket.new("127.0.0.1", "/", port)
          socket.on_ping { |_| pings.add(1) }
          spawn { socket.run }

          sleep 200.milliseconds
          pings.get.should be >= 2

          socket.close
          EchoChannel.closed.receive
        end
      ensure
        Azu::CONFIG.websocket.ping_interval = previous
      end
    end
  end
end

require "../spec_helper"

module Azu::ChannelDslSpec
  class CaptureSocket < HTTP::WebSocket
    getter sent = [] of String
    property broken = false

    def initialize
      super(IO::Memory.new, sync_close: false)
    end

    def send(message : String)
      raise IO::Error.new("closed") if broken
      @sent << message
    end
  end

  # Only overrides what it needs: every other hook has a default.
  class Chat < Azu::Channel
    getter received = [] of String

    def on_connect
      send({type: "welcome"})
    end

    def on_message(message : String)
      @received << message
      broadcast message, except_me: true
    end
  end

  class Lobby < Azu::Channel
  end

  def self.open(klass : Azu::Channel.class = Chat)
    socket = CaptureSocket.new
    channel = klass.new(socket)
    channel.call(HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(IO::Memory.new)))
    {channel, socket}
  end
end

describe Azu::Channel do
  it "works with only the hooks you override" do
    channel, socket = Azu::ChannelDslSpec.open
    socket.sent.should eq [%({"type":"welcome"})]
    channel.on_binary(Bytes.new(1))
    channel.on_ping("")
    channel.on_pong("")
    channel.on_close(nil, nil)
  end

  it "broadcasts to the other connections of the same channel" do
    a, a_socket = Azu::ChannelDslSpec.open
    _b, b_socket = Azu::ChannelDslSpec.open
    _lobby, lobby_socket = Azu::ChannelDslSpec.open(Azu::ChannelDslSpec::Lobby)

    a.on_message("hello")

    a_socket.sent.should eq [%({"type":"welcome"})]
    b_socket.sent.should eq [%({"type":"welcome"}), "hello"]
    lobby_socket.sent.should be_empty
  end

  it "broadcasts from outside an instance" do
    _, socket = Azu::ChannelDslSpec.open
    before = socket.sent.size
    Azu::ChannelDslSpec::Chat.broadcast("alert").should be >= 1
    socket.sent.size.should eq before + 1
  end

  it "targets rooms and leaves them on close" do
    a, a_socket = Azu::ChannelDslSpec.open
    b, b_socket = Azu::ChannelDslSpec.open
    a.join "red"
    b.join "blue"

    Azu::ChannelDslSpec::Chat.broadcast("red", "only red").should eq 1
    a_socket.sent.last.should eq "only red"
    b_socket.sent.should_not contain "only red"

    a.broadcast("blue", "to blue").should eq 1
    b_socket.sent.last.should eq "to blue"

    a.leave "red"
    Azu::ChannelDslSpec::Chat.broadcast("red", "nobody").should eq 0
  end

  it "forgets closed connections and survives broken sockets" do
    channel, socket = Azu::ChannelDslSpec.open
    count = Azu::ChannelDslSpec::Chat.connection_count
    socket.broken = true
    Azu::ChannelDslSpec::Chat.broadcast("x")
    Azu::ChannelDslSpec::Chat.connection_count.should eq count - 1
    channel.unregister
  end
end

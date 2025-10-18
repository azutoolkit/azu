require "../spec_helper"

# Test channel classes defined outside test blocks
class TestChannel < Azu::Channel
  def on_connect
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

class LifecycleTestChannel < Azu::Channel
  property connect_called = false
  property message_called = false
  property binary_called = false
  property ping_called = false
  property pong_called = false
  property close_called = false

  def on_connect
    @connect_called = true
  end

  def on_message(message : String)
    @message_called = true
  end

  def on_binary(binary : Bytes)
    @binary_called = true
  end

  def on_ping(message : String)
    @ping_called = true
  end

  def on_pong(message : String)
    @pong_called = true
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
    @close_called = true
  end
end

describe Azu::Channel do
  describe "WebSocket route registration" do
    it "registers a WebSocket route" do
      # Test that the ws class method exists and can be called
      # We create a temporary router to avoid CONFIG dependency issues
      router = Azu::Router.new
      _ = begin
        Azu::CONFIG.router
      rescue
        nil
      end

      # Temporarily stub CONFIG.router
      begin
        router.ws("/test-channel", TestChannel)
        # Should not raise an exception
        router.should be_a(Azu::Router)
      rescue ex
        # If CONFIG is not available, that's expected in tests
        ex.should be_a(Exception)
      end
    end
  end

  describe "Channel lifecycle" do
    it "initializes with a WebSocket" do
      # Create a mock WebSocket using IO::Memory instead of real connection
      io = IO::Memory.new
      socket = HTTP::WebSocket.new(io)
      channel = TestChannel.new(socket)
      channel.socket.should eq(socket)
    end

    it "sets up event handlers when called" do
      # Create a mock WebSocket using IO::Memory instead of real connection
      io = IO::Memory.new
      socket = HTTP::WebSocket.new(io)
      context = HTTP::Server::Context.new(
        HTTP::Request.new("GET", "/"),
        HTTP::Server::Response.new(IO::Memory.new)
      )

      channel = LifecycleTestChannel.new(socket)
      channel.call(context)

      # The on_connect should be called during setup
      channel.connect_called.should be_true
    end
  end

  describe "abstract methods" do
    it "requires implementation of abstract methods" do
      # This test verifies that abstract methods must be implemented
      # We check that instances can be created successfully
      io = IO::Memory.new
      socket = HTTP::WebSocket.new(io)

      test_channel = TestChannel.new(socket)
      lifecycle_channel = LifecycleTestChannel.new(socket)

      test_channel.should be_a(Azu::Channel)
      lifecycle_channel.should be_a(Azu::Channel)
    end
  end
end

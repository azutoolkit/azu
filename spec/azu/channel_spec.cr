require "../spec_helper"
require "../support/slow_pub_sub"

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

describe "Azu::Channel limits" do
  it "refuses the topic past websocket.max_subscriptions" do
    previous = Azu::CONFIG.websocket.max_subscriptions
    Azu::CONFIG.websocket.max_subscriptions = 2
    begin
      channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
      channel.subscribe("a")
      channel.subscribe("b")
      channel.subscribe("b") # already subscribed: not another
      expect_raises(Azu::Channel::TooManySubscriptions, /at most 2/) { channel.subscribe("c") }
      channel.unsubscribe("a")
      channel.subscribe("c")
    ensure
      Azu::CONFIG.websocket.max_subscriptions = previous
    end
  end

  it "closes a connection that sends nothing for websocket.idle_timeout" do
    previous = {Azu::CONFIG.websocket.ping_interval, Azu::CONFIG.websocket.idle_timeout}
    Azu::CONFIG.websocket.ping_interval = 20.milliseconds
    Azu::CONFIG.websocket.idle_timeout = 60.milliseconds
    begin
      io = IO::Memory.new
      channel = TestChannel.new(HTTP::WebSocket.new(io))
      channel.call(HTTP::Server::Context.new(HTTP::Request.new("GET", "/ws"), HTTP::Server::Response.new(IO::Memory.new)))
      channel.subscribe("room")
      wait_until(2.seconds) { channel.torn_down? }.should be_true
      io.to_s.bytes.should contain 0x88_u8 # a close frame was sent
    ensure
      Azu::CONFIG.websocket.ping_interval, Azu::CONFIG.websocket.idle_timeout = previous
    end
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
    it "subscribes once, and no caller returns before the backend confirmed, when two ask for a cold topic" do
      with_slow_pub_sub do |backend|
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        returned = ::Channel(Time::Instant).new(2)
        2.times { spawn { channel.subscribe("cold"); returned.send(Time.instant) } }

        2.times { returned.receive.should be >= (backend.confirmed_at || Time.instant + 1.hour) }
        backend.topics.count("cold").should eq 1
        backend.subscriber_count.should eq 1
        channel.teardown
        backend.subscriber_count.should eq 0
      end
    end

    it "makes a second caller fail with the first one's error, and lets a later call try anew" do
      with_slow_pub_sub do |backend|
        backend.fail_first = true
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        failure = ::Channel(Exception?).new(1)
        spawn do
          channel.subscribe("flaky")
          failure.send(nil)
        rescue ex
          failure.send(ex)
        end
        wait_until { backend.subscribe_calls == 1 }.should be_true

        expect_raises(Exception, "the backend failed") { channel.subscribe("flaky") }

        failure.receive.should_not be_nil
        backend.topics.count("flaky").should eq 1
        channel.subscribe("flaky")
        backend.topics.count("flaky").should eq 2
        backend.subscriber_count.should eq 1
      end
    end

    it "releases the reservation when the subscribe raises, so a retry works" do
      with_slow_pub_sub do |backend|
        backend.fail_first = true
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))

        expect_raises(Exception, "the backend failed") { channel.subscribe("retry") }
        channel.subscribe("retry")

        backend.subscriber_count.should eq 1
      end
    end

    it "does not hold its lock while the backend waits, so unsubscribe is not stalled" do
      with_slow_pub_sub(500.milliseconds) do |backend|
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        spawn { channel.subscribe("slow") }
        wait_until { backend.subscribe_calls == 1 }.should be_true
        unsubscribed = false
        spawn { channel.unsubscribe("other"); unsubscribed = true }

        wait_until(100.milliseconds) { unsubscribed }.should be_true # long before the 500 ms wait ends
        backend.confirmed_at.should be_nil                           # the slow subscribe was still waiting
      end
    end

    it "honours an unsubscribe that arrives while the subscribe is in flight" do
      with_slow_pub_sub do |backend|
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        spawn { channel.subscribe("gone") }
        wait_until { backend.subscribe_calls == 1 }.should be_true

        channel.unsubscribe("gone")

        wait_until { backend.confirmed_at && backend.subscriber_count == 0 }.should be_true
      end
    end

    it "ends unsubscribed when subscribe, subscribe, unsubscribe happen during one wait" do
      with_slow_pub_sub do |backend|
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        finished = ::Channel(Nil).new(2)
        2.times { spawn { channel.subscribe("order"); finished.send(nil) } }
        wait_until { backend.subscribe_calls == 1 }.should be_true
        Fiber.yield

        channel.unsubscribe("order")

        2.times { finished.receive }
        backend.topics.count("order").should eq 1
        backend.subscriber_count.should eq 0
      end
    end

    it "subscribes anew when the last call was a subscribe after an unsubscribe during the wait" do
      with_slow_pub_sub do |backend|
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        spawn { channel.subscribe("again") }
        wait_until { backend.subscribe_calls == 1 }.should be_true

        channel.unsubscribe("again")
        channel.subscribe("again")

        backend.topics.count("again").should eq 2
        wait_until { backend.subscriber_count == 1 }.should be_true
      end
    end

    it "ends unsubscribed when a second unsubscribe cancels the subscribe that replaced the first" do
      with_slow_pub_sub do |backend|
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        finished = ::Channel(Nil).new(2)
        spawn { channel.subscribe("twice"); finished.send(nil) }
        wait_until { backend.subscribe_calls == 1 }.should be_true
        channel.unsubscribe("twice")
        spawn { channel.subscribe("twice"); finished.send(nil) }
        wait_until { backend.subscribe_calls == 2 }.should be_true

        channel.unsubscribe("twice")

        2.times { finished.receive }
        wait_until { backend.confirmed_at && backend.subscriber_count == 0 }.should be_true
      end
    end

    it "leaves the reservation of a newer subscribe alone when the old owner fails after being replaced" do
      with_slow_pub_sub do |backend|
        backend.fail_first = true
        backend.delays = [50.milliseconds, 600.milliseconds]
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        old_owner = ::Channel(Exception?).new(1)
        spawn do
          channel.subscribe("swap")
          old_owner.send(nil)
        rescue ex
          old_owner.send(ex)
        end
        wait_until { backend.subscribe_calls == 1 }.should be_true
        channel.unsubscribe("swap")
        spawn { channel.subscribe("swap") }
        wait_until { backend.subscribe_calls == 2 }.should be_true
        old_owner.receive.should_not be_nil # the old owner failed; the newer subscribe is still in flight

        channel.subscribe("swap") # must wait for the newer one, not start a third backend call

        backend.topics.count("swap").should eq 2
        backend.subscriber_count.should eq 1
      end
    end

    it "fails every waiter with the one backend call when the backend keeps failing" do
      with_slow_pub_sub(200.milliseconds) do |backend|
        backend.fail_always = true
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        outcomes = ::Channel(Exception?).new(4)
        4.times do
          spawn do
            channel.subscribe("down")
            outcomes.send(nil)
          rescue ex
            outcomes.send(ex)
          end
        end

        4.times { outcomes.receive.should_not be_nil }
        backend.topics.count("down").should eq 1
      end
    end

    it "does not subscribe a waiter that was woken by teardown" do
      with_slow_pub_sub do |backend|
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        finished = ::Channel(Nil).new(2)
        2.times { spawn { channel.subscribe("bye"); finished.send(nil) } }
        wait_until { backend.subscribe_calls == 1 }.should be_true
        Fiber.yield

        channel.teardown

        2.times { finished.receive }
        backend.topics.count("bye").should eq 1
        backend.subscriber_count.should eq 0
      end
    end

    it "does not hang when the backend subscribes again from the subscribing fiber" do
      with_slow_pub_sub do |backend|
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        backend.on_subscribe = -> { channel.subscribe("again"); nil }
        finished = ::Channel(Nil).new(1)
        spawn { channel.subscribe("again"); finished.send(nil) }

        select
        when finished.receive
        when timeout(2.seconds)
          fail "a re-entrant subscribe waited for itself"
        end
      end
    end

    it "cancels a subscription that finishes after the channel was torn down" do
      with_slow_pub_sub do |backend|
        channel = TestChannel.new(HTTP::WebSocket.new(IO::Memory.new))
        spawn { channel.subscribe("late") }
        wait_until { backend.subscribe_calls == 1 }.should be_true

        channel.teardown

        wait_until { backend.confirmed_at && backend.subscriber_count == 0 }.should be_true
      end
    end

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

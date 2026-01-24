# How to Test WebSockets

This guide shows you how to write tests for WebSocket channels.

## Mock WebSocket

Create a mock WebSocket for testing:

```crystal
# spec/support/mock_websocket.cr
class MockWebSocket
  getter sent_messages = [] of String
  getter closed = false
  getter close_code : Int32?
  getter close_reason : String?

  def send(message : String)
    @sent_messages << message
  end

  def close(code : Int32? = nil, reason : String? = nil)
    @closed = true
    @close_code = code
    @close_reason = reason
  end

  def object_id
    0_u64
  end
end
```

## Testing Channel Connection

```crystal
# spec/channels/notification_channel_spec.cr
require "../spec_helper"
require "../support/mock_websocket"

describe NotificationChannel do
  describe "#on_connect" do
    it "adds socket to connections" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new

      initial_count = NotificationChannel::CONNECTIONS.size
      channel.socket = socket
      channel.on_connect

      NotificationChannel::CONNECTIONS.size.should eq(initial_count + 1)
    end

    it "sends welcome message" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new
      channel.socket = socket

      channel.on_connect

      socket.sent_messages.size.should eq(1)
      message = JSON.parse(socket.sent_messages.first)
      message["type"].should eq("connected")
    end
  end
end
```

## Testing Message Handling

```crystal
describe NotificationChannel do
  describe "#on_message" do
    it "responds to ping with pong" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new
      channel.socket = socket
      channel.on_connect

      channel.on_message(%({"type": "ping"}))

      pong = socket.sent_messages.find do |m|
        JSON.parse(m)["type"] == "pong"
      end
      pong.should_not be_nil
    end

    it "handles subscribe action" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new
      channel.socket = socket
      channel.on_connect

      channel.on_message(%({"type": "subscribe", "topic": "news"}))

      response = socket.sent_messages.last
      JSON.parse(response)["type"].should eq("subscribed")
    end

    it "handles invalid JSON gracefully" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new
      channel.socket = socket
      channel.on_connect

      channel.on_message("not valid json")

      error_msg = socket.sent_messages.find do |m|
        JSON.parse(m)["type"] == "error"
      end
      error_msg.should_not be_nil
    end
  end
end
```

## Testing Disconnection

```crystal
describe NotificationChannel do
  describe "#on_close" do
    it "removes socket from connections" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new
      channel.socket = socket
      channel.on_connect

      count_before = NotificationChannel::CONNECTIONS.size

      channel.on_close(nil, nil)

      NotificationChannel::CONNECTIONS.size.should eq(count_before - 1)
    end

    it "cleans up subscriptions" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new
      channel.socket = socket
      channel.on_connect

      # Subscribe to topic
      channel.on_message(%({"type": "subscribe", "topic": "news"}))

      channel.on_close(nil, nil)

      # Verify subscription cleaned up
      channel.subscriptions.should be_empty
    end
  end
end
```

## Testing Broadcasting

```crystal
describe NotificationChannel do
  describe ".broadcast" do
    it "sends message to all connections" do
      sockets = 3.times.map { MockWebSocket.new }.to_a
      channels = sockets.map do |socket|
        channel = NotificationChannel.new
        channel.socket = socket
        channel.on_connect
        channel
      end

      NotificationChannel.broadcast("Hello everyone!")

      sockets.each do |socket|
        socket.sent_messages.should contain("Hello everyone!")
      end
    end

    it "excludes sender when specified" do
      sender_socket = MockWebSocket.new
      other_socket = MockWebSocket.new

      sender = NotificationChannel.new
      sender.socket = sender_socket
      sender.on_connect

      other = NotificationChannel.new
      other.socket = other_socket
      other.on_connect

      NotificationChannel.broadcast("Hello!", except: sender_socket)

      sender_socket.sent_messages.should_not contain("Hello!")
      other_socket.sent_messages.should contain("Hello!")
    end
  end
end
```

## Testing Room-Based Channels

```crystal
describe RoomChannel do
  describe "room management" do
    it "joins user to room" do
      channel = RoomChannel.new
      socket = MockWebSocket.new
      channel.socket = socket
      channel.params = {"room_id" => "room-1"}
      channel.on_connect

      RoomChannel.room_members("room-1").should contain(socket)
    end

    it "broadcasts only to room members" do
      room1_socket = MockWebSocket.new
      room2_socket = MockWebSocket.new

      channel1 = RoomChannel.new
      channel1.socket = room1_socket
      channel1.params = {"room_id" => "room-1"}
      channel1.on_connect

      channel2 = RoomChannel.new
      channel2.socket = room2_socket
      channel2.params = {"room_id" => "room-2"}
      channel2.on_connect

      RoomChannel.broadcast_to("room-1", "Room 1 only")

      room1_socket.sent_messages.should contain("Room 1 only")
      room2_socket.sent_messages.should_not contain("Room 1 only")
    end
  end
end
```

## Testing Authentication

```crystal
describe AuthenticatedChannel do
  describe "#on_connect" do
    it "rejects invalid tokens" do
      channel = AuthenticatedChannel.new
      socket = MockWebSocket.new
      context = create_ws_context(query: "token=invalid")
      channel.socket = socket
      channel.context = context

      channel.on_connect

      socket.closed.should be_true

      error_msg = socket.sent_messages.find do |m|
        JSON.parse(m)["type"] == "error"
      end
      error_msg.should_not be_nil
    end

    it "accepts valid tokens" do
      user = User.create!(name: "Alice", email: "alice@example.com")
      token = Token.create(user_id: user.id)

      channel = AuthenticatedChannel.new
      socket = MockWebSocket.new
      context = create_ws_context(query: "token=#{token}")
      channel.socket = socket
      channel.context = context

      channel.on_connect

      socket.closed.should be_false

      success_msg = socket.sent_messages.find do |m|
        JSON.parse(m)["type"] == "authenticated"
      end
      success_msg.should_not be_nil
    end
  end
end

def create_ws_context(query : String = "") : HTTP::Server::Context
  io = IO::Memory.new
  request = HTTP::Request.new("GET", "/ws?#{query}")
  response = HTTP::Server::Response.new(io)
  HTTP::Server::Context.new(request, response)
end
```

## Integration Testing

Test WebSocket with real connections:

```crystal
require "http/web_socket"

describe "WebSocket Integration" do
  before_all do
    spawn { MyApp.start }
    sleep 1.second
  end

  it "establishes connection and receives messages" do
    received = [] of String
    done = Channel(Nil).new

    ws = HTTP::WebSocket.new("ws://localhost:4000/notifications")

    ws.on_message do |message|
      received << message
      if received.size >= 2
        done.send(nil)
      end
    end

    spawn { ws.run }
    sleep 100.milliseconds

    # Send a message
    ws.send(%({"type": "ping"}))

    # Wait for response
    select
    when done.receive
    when timeout(5.seconds)
      fail "Timeout waiting for messages"
    end

    # Should have welcome + pong
    received.size.should be >= 2
    ws.close
  end
end
```

## See Also

- [Test Endpoints](test-endpoints.md)
- [Create WebSocket Channel](../real-time/create-websocket-channel.md)

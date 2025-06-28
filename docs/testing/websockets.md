# WebSocket Testing

Comprehensive guide to testing WebSocket channels and real-time features in Azu applications.

## Overview

WebSocket testing in Azu focuses on testing real-time communication, channel connections, message handling, and live component interactions. This guide covers both unit and integration testing approaches for WebSocket functionality.

## WebSocket Test Setup

### Test Environment Configuration

```crystal
# spec/websocket/spec_helper.cr
require "../spec_helper"

# WebSocket test configuration
CONFIG.websocket_test = {
  host: "localhost",
  port: 3001,
  timeout: 5.seconds,
  reconnect_attempts: 3
}

# WebSocket test utilities
module WebSocketTestHelpers
  def self.create_test_server
    server = HTTP::Server.new([
      Azu::Handler::Rescuer.new,
      Azu::Handler::Logger.new
    ])

    # Register test channels
    TestChannel.ws "/ws/test"
    ChatChannel.ws "/ws/chat"
    NotificationChannel.ws "/ws/notifications"

    server
  end

  def self.create_test_client(uri : String) : HTTP::WebSocket
    HTTP::WebSocket.new(uri)
  end
end
```

### Test Channel Setup

```crystal
# spec/websocket/test_channels.cr
class TestChannel < Azu::Channel
  ws "/ws/test"

  def on_connect
    # Test connection logic
    broadcast("user_connected", {user_id: @user_id})
  end

  def on_message(message)
    # Echo message back for testing
    broadcast("echo", {message: message})
  end

  def on_disconnect
    broadcast("user_disconnected", {user_id: @user_id})
  end
end

class ChatChannel < Azu::Channel
  ws "/ws/chat/:room_id"

  def on_connect
    subscribe_to_room(@request.params["room_id"])
  end

  def on_message(message)
    broadcast_to_room(@request.params["room_id"], "message", {
      user_id: @user_id,
      content: message,
      timestamp: Time.utc
    })
  end
end
```

## Unit Testing WebSocket Channels

### Channel Connection Testing

```crystal
# spec/websocket/unit/channel_connection_spec.cr
require "../spec_helper"

describe TestChannel do
  describe "connection handling" do
    it "handles successful connections" do
      # Arrange
      channel = TestChannel.new
      mock_connection = MockWebSocketConnection.new

      # Act
      channel.on_connect(mock_connection)

      # Assert
      mock_connection.sent_messages.should contain("user_connected")
    end

    it "handles connection failures" do
      # Arrange
      channel = TestChannel.new
      mock_connection = MockWebSocketConnection.new(should_fail: true)

      # Act & Assert
      expect_raises(WebSocketConnectionError) do
        channel.on_connect(mock_connection)
      end
    end
  end
end
```

### Message Handling Testing

```crystal
# spec/websocket/unit/message_handling_spec.cr
describe TestChannel do
  describe "message handling" do
    it "processes valid messages" do
      # Arrange
      channel = TestChannel.new
      mock_connection = MockWebSocketConnection.new
      test_message = "Hello, WebSocket!"

      # Act
      channel.on_message(test_message, mock_connection)

      # Assert
      mock_connection.sent_messages.should contain("echo")
      mock_connection.last_message["message"].should eq(test_message)
    end

    it "handles malformed messages" do
      # Arrange
      channel = TestChannel.new
      mock_connection = MockWebSocketConnection.new
      malformed_message = ""

      # Act
      channel.on_message(malformed_message, mock_connection)

      # Assert
      mock_connection.sent_messages.should contain("error")
      mock_connection.last_message["error"].should eq("Message cannot be empty")
    end
  end
end
```

### Channel State Testing

```crystal
# spec/websocket/unit/channel_state_spec.cr
describe TestChannel do
  describe "channel state management" do
    it "tracks connected users" do
      # Arrange
      channel = TestChannel.new
      user1 = MockWebSocketConnection.new(user_id: "user1")
      user2 = MockWebSocketConnection.new(user_id: "user2")

      # Act
      channel.on_connect(user1)
      channel.on_connect(user2)

      # Assert
      channel.connected_users.size.should eq(2)
      channel.connected_users.should contain("user1")
      channel.connected_users.should contain("user2")
    end

    it "removes users on disconnect" do
      # Arrange
      channel = TestChannel.new
      user = MockWebSocketConnection.new(user_id: "user1")

      # Act
      channel.on_connect(user)
      channel.on_disconnect(user)

      # Assert
      channel.connected_users.size.should eq(0)
      channel.connected_users.should_not contain("user1")
    end
  end
end
```

## Integration Testing WebSocket

### Real WebSocket Connection Testing

```crystal
# spec/websocket/integration/real_connection_spec.cr
require "../spec_helper"

describe "Real WebSocket Connections" do
  describe "end-to-end communication" do
    it "establishes connection and exchanges messages" do
      # Start test server
      server = WebSocketTestHelpers.create_test_server
      server.bind_tcp(CONFIG.websocket_test.host, CONFIG.websocket_test.port)

      spawn do
        server.listen
      end

      # Give server time to start
      sleep(0.1)

      # Create client connection
      client = WebSocketTestHelpers.create_test_client(
        "ws://#{CONFIG.websocket_test.host}:#{CONFIG.websocket_test.port}/ws/test"
      )

      received_messages = [] of String

      client.on_message do |message|
        received_messages << message
      end

      # Connect and send message
      client.connect
      client.send("Hello, Server!")

      # Wait for response
      sleep(0.5)

      # Assert
      received_messages.should contain("user_connected")
      received_messages.should contain("echo")

      # Cleanup
      client.close
      server.close
    end
  end
end
```

### Multi-Client Testing

```crystal
# spec/websocket/integration/multi_client_spec.cr
describe "Multi-Client WebSocket Testing" do
  it "broadcasts messages to all connected clients" do
    server = WebSocketTestHelpers.create_test_server
    server.bind_tcp(CONFIG.websocket_test.host, CONFIG.websocket_test.port)

    spawn { server.listen }
    sleep(0.1)

    # Create multiple clients
    clients = [] of HTTP::WebSocket
    received_messages = [] of Array(String)

    3.times do |i|
      client = WebSocketTestHelpers.create_test_client(
        "ws://#{CONFIG.websocket_test.host}:#{CONFIG.websocket_test.port}/ws/test"
      )

      messages = [] of String
      client.on_message { |msg| messages << msg }

      client.connect
      clients << client
      received_messages << messages
    end

    # Send message from first client
    clients[0].send("Broadcast message")

    # Wait for broadcast
    sleep(0.5)

    # Verify all clients received the message
    received_messages.each do |messages|
      messages.should contain("echo")
    end

    # Cleanup
    clients.each(&.close)
    server.close
  end
end
```

## Live Component Testing

### Component Rendering Testing

```crystal
# spec/websocket/components/live_component_spec.cr
describe LiveUserListComponent do
  describe "real-time updates" do
    it "updates when users connect" do
      # Arrange
      component = LiveUserListComponent.new
      initial_html = component.render

      # Act - simulate user connection
      component.on_event("user_connected", {"user_id" => "user1", "name" => "John"})

      # Assert
      updated_html = component.render
      updated_html.should_not eq(initial_html)
      updated_html.should contain("John")
    end

    it "updates when users disconnect" do
      # Arrange
      component = LiveUserListComponent.new
      component.on_event("user_connected", {"user_id" => "user1", "name" => "John"})

      # Act - simulate user disconnection
      component.on_event("user_disconnected", {"user_id" => "user1"})

      # Assert
      html = component.render
      html.should_not contain("John")
    end
  end
end
```

### Component Event Testing

```crystal
# spec/websocket/components/component_events_spec.cr
describe ChatComponent do
  describe "message handling" do
    it "processes new messages" do
      # Arrange
      component = ChatComponent.new(room_id: "room1")

      # Act
      result = component.on_event("new_message", {
        "user_id" => "user1",
        "content" => "Hello, everyone!",
        "timestamp" => Time.utc.to_s
      })

      # Assert
      result.should be_a(Component::EventResult)
      result.action.should eq("append_message")

      # Verify message was added
      html = component.render
      html.should contain("Hello, everyone!")
    end

    it "handles message validation" do
      # Arrange
      component = ChatComponent.new(room_id: "room1")

      # Act - empty message
      result = component.on_event("new_message", {
        "user_id" => "user1",
        "content" => "",
        "timestamp" => Time.utc.to_s
      })

      # Assert
      result.action.should eq("show_error")
      result.data["error"].should eq("Message cannot be empty")
    end
  end
end
```

## Spark System Testing

### Spark Event Testing

```crystal
# spec/websocket/spark/spark_events_spec.cr
describe Azu::Spark do
  describe "event broadcasting" do
    it "broadcasts events to connected clients" do
      # Arrange
      spark = Azu::Spark.new
      mock_client = MockSparkClient.new
      spark.add_client(mock_client)

      # Act
      spark.broadcast("user_updated", {"user_id" => "user1", "name" => "Updated Name"})

      # Assert
      mock_client.received_events.should contain("user_updated")
      mock_client.last_event_data["user_id"].should eq("user1")
    end

    it "handles client disconnection" do
      # Arrange
      spark = Azu::Spark.new
      mock_client = MockSparkClient.new
      spark.add_client(mock_client)

      # Act
      spark.remove_client(mock_client)
      spark.broadcast("test_event", {"data" => "test"})

      # Assert
      mock_client.received_events.should_not contain("test_event")
    end
  end
end
```

### Spark Channel Testing

```crystal
# spec/websocket/spark/spark_channels_spec.cr
describe Azu::Spark::Channel do
  describe "channel subscriptions" do
    it "subscribes clients to channels" do
      # Arrange
      channel = Azu::Spark::Channel.new("test_channel")
      mock_client = MockSparkClient.new

      # Act
      channel.subscribe(mock_client)
      channel.broadcast("channel_message", {"content" => "Hello"})

      # Assert
      mock_client.received_events.should contain("channel_message")
    end

    it "unsubscribes clients from channels" do
      # Arrange
      channel = Azu::Spark::Channel.new("test_channel")
      mock_client = MockSparkClient.new
      channel.subscribe(mock_client)

      # Act
      channel.unsubscribe(mock_client)
      channel.broadcast("channel_message", {"content" => "Hello"})

      # Assert
      mock_client.received_events.should_not contain("channel_message")
    end
  end
end
```

## Mock Objects for Testing

### Mock WebSocket Connection

```crystal
# spec/websocket/mocks/mock_websocket.cr
class MockWebSocketConnection
  property user_id : String
  property sent_messages : Array(String)
  property should_fail : Bool

  def initialize(@user_id = "test_user", @should_fail = false)
    @sent_messages = [] of String
  end

  def send(message : String)
    raise WebSocketConnectionError.new if @should_fail
    @sent_messages << message
  end

  def close
    # Mock close behavior
  end

  def last_message : Hash(String, String)
    return {} of String => String if @sent_messages.empty?

    # Parse last message as JSON
    JSON.parse(@sent_messages.last).as_h.transform_values(&.to_s)
  end
end
```

### Mock Spark Client

```crystal
# spec/websocket/mocks/mock_spark_client.cr
class MockSparkClient
  property received_events : Array(String)
  property last_event_data : Hash(String, String)

  def initialize
    @received_events = [] of String
    @last_event_data = {} of String => String
  end

  def send_event(event_name : String, data : Hash)
    @received_events << event_name
    @last_event_data = data.transform_values(&.to_s)
  end

  def subscribed_channels : Array(String)
    # Mock subscribed channels
    [] of String
  end
end
```

## Performance Testing

### Connection Load Testing

```crystal
# spec/websocket/performance/load_spec.cr
describe "WebSocket Load Testing" do
  it "handles multiple concurrent connections" do
    server = WebSocketTestHelpers.create_test_server
    server.bind_tcp(CONFIG.websocket_test.host, CONFIG.websocket_test.port)

    spawn { server.listen }
    sleep(0.1)

    # Create many concurrent connections
    clients = [] of HTTP::WebSocket
    connection_count = 100

    connection_count.times do |i|
      client = WebSocketTestHelpers.create_test_client(
        "ws://#{CONFIG.websocket_test.host}:#{CONFIG.websocket_test.port}/ws/test"
      )

      begin
        client.connect
        clients << client
      rescue ex
        # Handle connection failures
      end
    end

    # Verify most connections succeeded
    successful_connections = clients.size
    success_rate = successful_connections.to_f / connection_count

    success_rate.should be >= 0.95 # 95% success rate

    # Cleanup
    clients.each(&.close)
    server.close
  end
end
```

### Message Throughput Testing

```crystal
# spec/websocket/performance/throughput_spec.cr
describe "WebSocket Message Throughput" do
  it "handles high message volume" do
    server = WebSocketTestHelpers.create_test_server
    server.bind_tcp(CONFIG.websocket_test.host, CONFIG.websocket_test.port)

    spawn { server.listen }
    sleep(0.1)

    client = WebSocketTestHelpers.create_test_client(
      "ws://#{CONFIG.websocket_test.host}:#{CONFIG.websocket_test.port}/ws/test"
    )

    received_count = 0
    client.on_message { |msg| received_count += 1 }
    client.connect

    # Send many messages quickly
    start_time = Time.monotonic
    1000.times do |i|
      client.send("Message #{i}")
    end

    # Wait for processing
    sleep(2)
    end_time = Time.monotonic

    # Calculate throughput
    duration = end_time - start_time
    throughput = received_count / duration.total_seconds

    # Assert reasonable throughput
    throughput.should be >= 100 # At least 100 messages per second

    client.close
    server.close
  end
end
```

## Error Handling Testing

### Connection Error Testing

```crystal
# spec/websocket/errors/connection_errors_spec.cr
describe "WebSocket Error Handling" do
  it "handles connection timeouts" do
    # Test with slow server
    slow_server = HTTP::Server.new do |context|
      sleep(10) # Simulate slow response
    end

    slow_server.bind_tcp(CONFIG.websocket_test.host, CONFIG.websocket_test.port)
    spawn { slow_server.listen }

    client = WebSocketTestHelpers.create_test_client(
      "ws://#{CONFIG.websocket_test.host}:#{CONFIG.websocket_test.port}/ws/test"
    )

    # Should timeout
    expect_raises(HTTP::TimeoutError) do
      client.connect(timeout: 1.second)
    end

    slow_server.close
  end

  it "handles malformed messages" do
    server = WebSocketTestHelpers.create_test_server
    server.bind_tcp(CONFIG.websocket_test.host, CONFIG.websocket_test.port)

    spawn { server.listen }
    sleep(0.1)

    client = WebSocketTestHelpers.create_test_client(
      "ws://#{CONFIG.websocket_test.host}:#{CONFIG.websocket_test.port}/ws/test"
    )

    client.connect

    # Send malformed message
    client.send("") # Empty message

    # Should handle gracefully
    sleep(0.1)

    client.close
    server.close
  end
end
```

## Test Utilities

### WebSocket Test Helpers

```crystal
# spec/websocket/helpers/websocket_helpers.cr
module WebSocketHelpers
  def self.wait_for_message(client : HTTP::WebSocket, expected_message : String, timeout : Time::Span = 5.seconds) : Bool
    start_time = Time.monotonic
    received_messages = [] of String

    client.on_message do |message|
      received_messages << message
      return true if message.includes?(expected_message)
    end

    while Time.monotonic - start_time < timeout
      sleep(0.1)
      return true if received_messages.any? { |msg| msg.includes?(expected_message) }
    end

    false
  end

  def self.create_test_message(type : String, data : Hash) : String
    {
      "type" => type,
      "data" => data,
      "timestamp" => Time.utc.to_s
    }.to_json
  end
end
```

## Running WebSocket Tests

### Test Commands

```bash
# Run all WebSocket tests
crystal spec spec/websocket/

# Run unit tests only
crystal spec spec/websocket/unit/

# Run integration tests only
crystal spec spec/websocket/integration/

# Run with verbose output
crystal spec spec/websocket/ --verbose

# Run specific test file
crystal spec spec/websocket/unit/channel_connection_spec.cr
```

### CI/CD Integration

```yaml
# .github/workflows/websocket-tests.yml
name: WebSocket Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  websocket-tests:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v3
      - name: Setup Crystal
        uses: crystal-lang/install-crystal@v1
      - name: Install dependencies
        run: shards install
      - name: Run WebSocket tests
        run: crystal spec spec/websocket/
      - name: Run WebSocket performance tests
        run: crystal spec spec/websocket/performance/
```

## Best Practices

### 1. Test Realistic Scenarios

```crystal
# Test realistic WebSocket usage patterns
describe "Realistic WebSocket Usage" do
  it "handles typical chat room scenario" do
    # Setup chat room
    # Connect multiple users
    # Exchange messages
    # Handle disconnections
    # Verify message delivery
  end
end
```

### 2. Test Edge Cases

```crystal
# Test edge cases
describe "WebSocket Edge Cases" do
  it "handles rapid connect/disconnect cycles" do
    # Test rapid connection attempts
  end

  it "handles large message payloads" do
    # Test messages exceeding size limits
  end

  it "handles network interruptions" do
    # Test connection drops and reconnections
  end
end
```

### 3. Test Performance Boundaries

```crystal
# Test performance boundaries
describe "WebSocket Performance Boundaries" do
  it "handles maximum concurrent connections" do
    # Test system limits
  end

  it "handles maximum message frequency" do
    # Test rate limiting
  end
end
```

## Next Steps

- [Unit Testing](unit.md) - Test individual components
- [Integration Testing](integration.md) - Test component interactions
- [Testing Best Practices](testing.md) - General testing guidelines

---

_WebSocket testing ensures your real-time features work reliably and handle edge cases gracefully._

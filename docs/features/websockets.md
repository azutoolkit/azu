# WebSockets

Azu provides powerful WebSocket support for building real-time applications. With type-safe channels, automatic connection management, and efficient message handling, you can create interactive, responsive user experiences.

## What are WebSockets?

WebSockets in Azu provide:

- **Real-time Communication**: Bidirectional communication between client and server
- **Type Safety**: Type-safe message handling and broadcasting
- **Connection Management**: Automatic connection and disconnection handling
- **Event Broadcasting**: Notify all connected clients of changes
- **Message Validation**: Validate incoming WebSocket messages

## Basic WebSocket Channel

```crystal
class ChatChannel < Azu::Channel
  CONNECTIONS = Set(HTTP::WebSocket).new

  ws "/chat"

  def on_connect
    CONNECTIONS << socket.not_nil!
    send_to_client({
      type: "connected",
      message: "Connected to chat",
      timestamp: Time.utc.to_rfc3339
    })

    Log.info { "User connected. Total connections: #{CONNECTIONS.size}" }
  end

  def on_message(message : String)
    begin
      data = JSON.parse(message)
      handle_message(data)
    rescue JSON::ParseException
      send_error("Invalid JSON format")
    end
  end

  def on_close(code, message)
    CONNECTIONS.delete(socket)
    Log.info { "User disconnected. Total connections: #{CONNECTIONS.size}" }
  end

  private def handle_message(data : JSON::Any)
    case data["type"]?.try(&.as_s)
    when "ping"
      send_to_client({type: "pong", timestamp: Time.utc.to_rfc3339})
    when "message"
      broadcast_message(data["content"].as_s, data["user"].as_s)
    when "typing"
      broadcast_typing(data["user"].as_s, data["is_typing"].as_bool)
    else
      send_error("Unknown message type")
    end
  end

  private def broadcast_message(content : String, user : String)
    message = {
      type: "message",
      content: content,
      user: user,
      timestamp: Time.utc.to_rfc3339
    }

    broadcast_to_all(message)
  end

  private def broadcast_typing(user : String, is_typing : Bool)
    message = {
      type: "typing",
      user: user,
      is_typing: is_typing,
      timestamp: Time.utc.to_rfc3339
    }

    broadcast_to_all(message)
  end

  private def send_to_client(data)
    socket.not_nil!.send(data.to_json)
  end

  private def send_error(message : String)
    send_to_client({type: "error", message: message})
  end

  private def broadcast_to_all(message)
    CONNECTIONS.each do |socket|
      spawn socket.send(message.to_json)
    end
  end
end
```

## Channel Registration

Register WebSocket channels in your application:

```crystal
module MyApp
  include Azu

  configure do |config|
    # WebSocket configuration
    config.websocket.ping_interval = 30.seconds
    config.websocket.ping_timeout = 10.seconds
    config.websocket.max_message_size = 1024 * 1024  # 1MB
  end

  # Register channels
  router do
    # WebSocket routes
    ws "/chat", ChatChannel
    ws "/notifications", NotificationChannel
    ws "/game/:room_id", GameChannel
  end
end
```

## Message Types

Handle different types of WebSocket messages:

### Text Messages

```crystal
def on_message(message : String)
  # Handle text message
  send_to_client("Echo: #{message}")
end
```

### JSON Messages

```crystal
def on_message(message : String)
  begin
    data = JSON.parse(message)
    handle_json_message(data)
  rescue JSON::ParseException
    send_error("Invalid JSON format")
  end
end

private def handle_json_message(data : JSON::Any)
  case data["type"]?.try(&.as_s)
  when "ping"
    send_pong
  when "chat"
    handle_chat_message(data)
  when "typing"
    handle_typing(data)
  else
    send_error("Unknown message type")
  end
end
```

### Binary Messages

```crystal
def on_binary_message(message : Bytes)
  # Handle binary message
  send_binary_response(message)
end

private def send_binary_response(data : Bytes)
  socket.not_nil!.send(data)
end
```

## Connection Management

### Connection Lifecycle

```crystal
class ConnectionChannel < Azu::Channel
  ws "/connection"

  def on_connect
    # Connection established
    Log.info { "WebSocket connection established" }

    # Send welcome message
    send_to_client({
      type: "welcome",
      message: "Connected successfully",
      timestamp: Time.utc.to_rfc3339
    })
  end

  def on_close(code, message)
    # Connection closed
    Log.info { "WebSocket connection closed: #{code} - #{message}" }

    # Clean up resources
    cleanup_connection
  end

  private def cleanup_connection
    # Remove from active connections
    # Clean up user session
    # Notify other users
  end
end
```

### Connection Validation

```crystal
class AuthenticatedChannel < Azu::Channel
  ws "/authenticated"

  def on_connect
    # Validate authentication
    unless authenticated?
      close_connection(1008, "Authentication required")
      return
    end

    # Proceed with connection
    send_to_client({type: "authenticated", user: current_user.to_json})
  end

  private def authenticated? : Bool
    # Check authentication token
    token = context.request.headers["Authorization"]?
    return false unless token

    # Validate token
    validate_token(token)
  end

  private def current_user
    # Get current user from token
    decode_token(get_auth_token)
  end
end
```

## Broadcasting

### Broadcast to All Connections

```crystal
class BroadcastChannel < Azu::Channel
  CONNECTIONS = Set(HTTP::WebSocket).new

  ws "/broadcast"

  def on_connect
    CONNECTIONS << socket.not_nil!
  end

  def on_close(code, message)
    CONNECTIONS.delete(socket)
  end

  # Broadcast to all connected clients
  def self.broadcast_to_all(message)
    CONNECTIONS.each do |socket|
      spawn socket.send(message.to_json)
    end
  end

  # Broadcast to specific users
  def self.broadcast_to_users(user_ids : Array(Int64), message)
    user_ids.each do |user_id|
      if socket = get_socket_for_user(user_id)
        socket.send(message.to_json)
      end
    end
  end
end
```

### Room-based Broadcasting

```crystal
class RoomChannel < Azu::Channel
  ROOMS = {} of String => Set(HTTP::WebSocket)

  ws "/room/:room_id"

  def on_connect
    room_id = params["room_id"]
    ROOMS[room_id] ||= Set(HTTP::WebSocket).new
    ROOMS[room_id] << socket.not_nil!

    # Notify room of new user
    broadcast_to_room(room_id, {
      type: "user_joined",
      user: current_user.to_json,
      timestamp: Time.utc.to_rfc3339
    })
  end

  def on_close(code, message)
    room_id = params["room_id"]
    ROOMS[room_id]?.delete(socket)

    # Notify room of user leaving
    broadcast_to_room(room_id, {
      type: "user_left",
      user: current_user.to_json,
      timestamp: Time.utc.to_rfc3339
    })
  end

  def on_message(message : String)
    room_id = params["room_id"]
    data = JSON.parse(message)

    # Broadcast message to room
    broadcast_to_room(room_id, {
      type: "message",
      content: data["content"].as_s,
      user: current_user.to_json,
      timestamp: Time.utc.to_rfc3339
    })
  end

  private def broadcast_to_room(room_id : String, message)
    ROOMS[room_id]?.each do |socket|
      spawn socket.send(message.to_json)
    end
  end
end
```

## Real-time Features

### Live Notifications

```crystal
class NotificationChannel < Azu::Channel
  USER_CONNECTIONS = {} of Int64 => HTTP::WebSocket

  ws "/notifications"

  def on_connect
    user_id = current_user.id
    USER_CONNECTIONS[user_id] = socket.not_nil!

    # Send pending notifications
    send_pending_notifications(user_id)
  end

  def on_close(code, message)
    user_id = current_user.id
    USER_CONNECTIONS.delete(user_id)
  end

  # Send notification to specific user
  def self.notify_user(user_id : Int64, notification)
    if socket = USER_CONNECTIONS[user_id]?
      socket.send(notification.to_json)
    else
      # Store for later delivery
      store_notification(user_id, notification)
    end
  end

  # Broadcast system notification
  def self.broadcast_system_notification(notification)
    USER_CONNECTIONS.each do |user_id, socket|
      spawn socket.send(notification.to_json)
    end
  end
end
```

### Live Updates

```crystal
class LiveUpdateChannel < Azu::Channel
  ws "/live_updates"

  def on_connect
    # Subscribe to specific updates
    subscribe_to_updates
  end

  def on_message(message : String)
    data = JSON.parse(message)

    case data["type"]?.try(&.as_s)
    when "subscribe"
      subscribe_to_resource(data["resource"].as_s, data["id"].as_i64)
    when "unsubscribe"
      unsubscribe_from_resource(data["resource"].as_s, data["id"].as_i64)
    end
  end

  private def subscribe_to_updates
    # Subscribe to user-specific updates
    user_id = current_user.id
    subscribe_to_resource("user", user_id)
  end

  private def subscribe_to_resource(resource : String, id : Int64)
    case resource
    when "user"
      subscribe_to_user_updates(id)
    when "post"
      subscribe_to_post_updates(id)
    when "comment"
      subscribe_to_comment_updates(id)
    end
  end
end
```

## Error Handling

### WebSocket Error Handling

```crystal
class ErrorHandlingChannel < Azu::Channel
  ws "/error_handling"

  def on_message(message : String)
    begin
      data = JSON.parse(message)
      handle_message(data)
    rescue JSON::ParseException
      send_error("Invalid JSON format")
    rescue e
      Log.error(exception: e) { "Error handling message" }
      send_error("Internal server error")
    end
  end

  private def handle_message(data : JSON::Any)
    # Message handling logic
  end

  private def send_error(message : String)
    send_to_client({
      type: "error",
      message: message,
      timestamp: Time.utc.to_rfc3339
    })
  end
end
```

### Connection Error Handling

```crystal
class RobustChannel < Azu::Channel
  ws "/robust"

  def on_connect
    begin
      # Connection setup
      setup_connection
    rescue e
      Log.error(exception: e) { "Error setting up connection" }
      close_connection(1011, "Connection setup failed")
    end
  end

  def on_close(code, message)
    begin
      # Cleanup
      cleanup_connection
    rescue e
      Log.error(exception: e) { "Error during cleanup" }
    end
  end

  private def setup_connection
    # Connection setup logic
  end

  private def cleanup_connection
    # Cleanup logic
  end
end
```

## Testing WebSockets

Test your WebSocket channels:

```crystal
require "spec"

describe ChatChannel do
  it "handles connection" do
    channel = ChatChannel.new
    context = create_websocket_context

    channel.on_connect

    # Assert connection handling
    channel.connections.size.should eq(1)
  end

  it "handles messages" do
    channel = ChatChannel.new
    context = create_websocket_context

    channel.on_connect
    channel.on_message('{"type": "ping"}')

    # Assert message handling
    # Check for pong response
  end

  it "handles disconnection" do
    channel = ChatChannel.new
    context = create_websocket_context

    channel.on_connect
    channel.on_close(1000, "Normal closure")

    # Assert disconnection handling
    channel.connections.size.should eq(0)
  end
end
```

## Performance Considerations

### Connection Pooling

```crystal
class PooledChannel < Azu::Channel
  ws "/pooled"

  def initialize
    @connection_pool = ConnectionPool.new(max_size: 100)
  end

  def on_connect
    connection = @connection_pool.acquire
    # Use connection
  end

  def on_close(code, message)
    @connection_pool.release(connection)
  end
end
```

### Message Batching

```crystal
class BatchedChannel < Azu::Channel
  ws "/batched"

  def initialize
    @message_queue = [] of String
    @batch_size = 10
    @batch_timeout = 100.milliseconds
  end

  def on_message(message : String)
    @message_queue << message

    if @message_queue.size >= @batch_size
      process_batch
    else
      schedule_batch_processing
    end
  end

  private def process_batch
    messages = @message_queue.dup
    @message_queue.clear

    # Process batch of messages
    process_messages(messages)
  end
end
```

## Security Considerations

### Authentication

```crystal
class SecureChannel < Azu::Channel
  ws "/secure"

  def on_connect
    unless authenticated?
      close_connection(1008, "Authentication required")
      return
    end

    # Proceed with authenticated connection
  end

  private def authenticated? : Bool
    # Validate authentication token
    token = get_auth_token
    validate_token(token)
  end
end
```

### Rate Limiting

```crystal
class RateLimitedChannel < Azu::Channel
  ws "/rate_limited"

  def initialize
    @message_counts = {} of String => Int32
    @rate_limit = 100  # messages per minute
  end

  def on_message(message : String)
    client_id = get_client_id

    # Check rate limit
    if rate_limited?(client_id)
      send_error("Rate limit exceeded")
      return
    end

    # Process message
    handle_message(message)
  end

  private def rate_limited?(client_id : String) : Bool
    count = @message_counts[client_id] || 0
    count >= @rate_limit
  end
end
```

## Best Practices

### 1. Handle Connection Lifecycle

```crystal
class LifecycleChannel < Azu::Channel
  ws "/lifecycle"

  def on_connect
    # Setup connection
    setup_connection
  end

  def on_close(code, message)
    # Cleanup connection
    cleanup_connection
  end

  private def setup_connection
    # Connection setup logic
  end

  private def cleanup_connection
    # Cleanup logic
  end
end
```

### 2. Validate Messages

```crystal
class ValidatedChannel < Azu::Channel
  ws "/validated"

  def on_message(message : String)
    begin
      data = JSON.parse(message)
      validate_message(data)
      handle_message(data)
    rescue JSON::ParseException
      send_error("Invalid JSON format")
    rescue ValidationError
      send_error("Invalid message format")
    end
  end

  private def validate_message(data : JSON::Any)
    # Validate message structure
    raise ValidationError.new("Missing required fields") unless data["type"]?
  end
end
```

### 3. Use Type Safety

```crystal
class TypeSafeChannel < Azu::Channel
  ws "/type_safe"

  def on_message(message : String)
    data = JSON.parse(message)

    case data["type"]?.try(&.as_s)
    when "ping"
      handle_ping(data)
    when "message"
      handle_message(data)
    else
      send_error("Unknown message type")
    end
  end

  private def handle_ping(data : JSON::Any)
    send_to_client({type: "pong", timestamp: Time.utc.to_rfc3339})
  end

  private def handle_message(data : JSON::Any)
    content = data["content"]?.try(&.as_s) || ""
    user = data["user"]?.try(&.as_s) || "anonymous"

    broadcast_message(content, user)
  end
end
```

## Next Steps

Now that you understand WebSockets:

1. **[Components](components.md)** - Build interactive UI components
2. **[Templates](templates.md)** - Create real-time templates
3. **[Caching](caching.md)** - Implement WebSocket caching
4. **[Testing](../testing.md)** - Test your WebSocket channels
5. **[Performance](../advanced/performance.md)** - Optimize WebSocket performance

---

_WebSockets in Azu provide a powerful foundation for building real-time applications. With type safety, connection management, and efficient broadcasting, they enable interactive, responsive user experiences._

# How to Broadcast Messages

This guide shows you how to broadcast messages to multiple WebSocket clients.

## Basic Broadcasting

Broadcast to all connected clients:

```crystal
class NotificationChannel < Azu::Channel
  PATH = "/notifications"

  CONNECTIONS = [] of HTTP::WebSocket

  def on_connect
    CONNECTIONS << socket
  end

  def on_close(code, reason)
    CONNECTIONS.delete(socket)
  end

  def self.broadcast(message : String)
    CONNECTIONS.each do |ws|
      ws.send(message)
    end
  end
end
```

Trigger broadcast from anywhere:

```crystal
# In an endpoint
def call
  user = User.create!(create_user_request)

  NotificationChannel.broadcast({
    type: "user_created",
    user: {id: user.id, name: user.name}
  }.to_json)

  UserResponse.new(user)
end
```

## Broadcast to Others

Broadcast to all except the sender:

```crystal
class ChatChannel < Azu::Channel
  PATH = "/chat"

  CONNECTIONS = [] of HTTP::WebSocket

  def on_message(message : String)
    # Broadcast to everyone except sender
    CONNECTIONS.each do |ws|
      ws.send(message) unless ws == socket
    end
  end
end
```

## Room-based Broadcasting

Broadcast to specific rooms:

```crystal
class RoomChannel < Azu::Channel
  PATH = "/rooms/:room_id"

  @@rooms = Hash(String, Set(HTTP::WebSocket)).new { |h, k| h[k] = Set(HTTP::WebSocket).new }

  def on_connect
    room_id = params["room_id"]
    @@rooms[room_id] << socket
  end

  def on_close(code, reason)
    room_id = params["room_id"]
    @@rooms[room_id].delete(socket)
  end

  def self.broadcast_to(room_id : String, message : String)
    @@rooms[room_id].each(&.send(message))
  end

  def self.broadcast_to_all(message : String)
    @@rooms.each_value do |sockets|
      sockets.each(&.send(message))
    end
  end
end
```

## User-targeted Broadcasting

Send to specific users:

```crystal
class UserChannel < Azu::Channel
  PATH = "/user"

  @@user_sockets = Hash(Int64, Set(HTTP::WebSocket)).new { |h, k| h[k] = Set(HTTP::WebSocket).new }

  def on_connect
    if user = authenticate
      @@user_sockets[user.id] << socket
    end
  end

  def on_close(code, reason)
    if user = @current_user
      @@user_sockets[user.id].delete(socket)
    end
  end

  def self.send_to_user(user_id : Int64, message : String)
    @@user_sockets[user_id].each(&.send(message))
  end

  def self.send_to_users(user_ids : Array(Int64), message : String)
    user_ids.each { |id| send_to_user(id, message) }
  end
end
```

## Broadcast with Filtering

Filter recipients based on criteria:

```crystal
class FilteredChannel < Azu::Channel
  PATH = "/feed"

  record Connection, socket : HTTP::WebSocket, topics : Set(String)

  @@connections = [] of Connection

  def on_connect
    topics = params["topics"]?.try(&.split(",").to_set) || Set(String).new
    @@connections << Connection.new(socket, topics)
  end

  def self.broadcast(topic : String, message : String)
    @@connections.each do |conn|
      if conn.topics.includes?(topic)
        conn.socket.send(message)
      end
    end
  end
end
```

## Async Broadcasting

Use fibers for non-blocking broadcasts:

```crystal
def self.broadcast_async(message : String)
  spawn do
    CONNECTIONS.each do |ws|
      begin
        ws.send(message)
      rescue
        # Handle disconnected socket
      end
    end
  end
end
```

## Broadcast from Background Jobs

Trigger broadcasts from background processes:

```crystal
# Background job
class OrderProcessor
  def process(order_id : Int64)
    order = Order.find!(order_id)
    order.process!

    # Notify the user
    UserChannel.send_to_user(order.user_id, {
      type: "order_updated",
      order_id: order.id,
      status: order.status
    }.to_json)
  end
end
```

## Rate-limited Broadcasting

Prevent broadcast flooding:

```crystal
class ThrottledChannel < Azu::Channel
  @@last_broadcast = Time.utc
  @@min_interval = 100.milliseconds

  def self.broadcast(message : String)
    now = Time.utc
    return if now - @@last_broadcast < @@min_interval

    @@last_broadcast = now
    CONNECTIONS.each(&.send(message))
  end
end
```

## Batched Broadcasting

Batch multiple messages:

```crystal
class BatchedChannel < Azu::Channel
  @@pending_messages = [] of String
  @@flush_scheduled = false

  def self.queue(message : String)
    @@pending_messages << message
    schedule_flush unless @@flush_scheduled
  end

  private def self.schedule_flush
    @@flush_scheduled = true
    spawn do
      sleep 50.milliseconds
      flush
    end
  end

  private def self.flush
    return if @@pending_messages.empty?

    batch = {type: "batch", messages: @@pending_messages}.to_json
    CONNECTIONS.each(&.send(batch))

    @@pending_messages.clear
    @@flush_scheduled = false
  end
end
```

## See Also

- [Create WebSocket Channel](create-websocket-channel.md)
- [Build Live Component](build-live-component.md)

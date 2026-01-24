# Understanding Real-Time Features

This document explains Azu's real-time capabilities through WebSocket channels and how they enable bidirectional communication.

## Why Real-Time?

Traditional HTTP is request-response:

```
Client: "Give me data"
Server: "Here's data"
Client: "Give me data again"
Server: "Here's data"
...
```

Real-time applications need:
- Instant updates without polling
- Server-initiated messages
- Efficient bidirectional communication

WebSockets provide:
```
Client ←→ Server
    Persistent connection
    Messages flow both ways
    Low latency
```

## WebSocket Channels

Channels are the Azu abstraction for WebSocket connections:

```crystal
class ChatChannel < Azu::Channel
  PATH = "/chat"

  def on_connect
    # Connection established
  end

  def on_message(message : String)
    # Message received
  end

  def on_close(code, reason)
    # Connection closed
  end
end
```

### Channel Lifecycle

```
Client connects via WebSocket
         ↓
    on_connect
         ↓
    ┌────────┐
    │  Loop  │ ←── on_message (for each message)
    └────────┘
         ↓
    on_close
```

## Connection Management

### Tracking Connections

Channels typically maintain a collection of active connections:

```crystal
class NotificationChannel < Azu::Channel
  PATH = "/notifications"

  @@connections = [] of HTTP::WebSocket

  def on_connect
    @@connections << socket
    send_welcome
  end

  def on_close(code, reason)
    @@connections.delete(socket)
  end
end
```

### Broadcasting

Send messages to multiple clients:

```crystal
def self.broadcast(message : String)
  @@connections.each do |socket|
    socket.send(message)
  end
end
```

This enables:
- Chat rooms
- Live notifications
- Real-time dashboards
- Collaborative editing

## Message Protocol

### JSON Messages

Typically, messages are JSON:

```crystal
def on_message(message : String)
  data = JSON.parse(message)

  case data["type"]?.try(&.as_s)
  when "subscribe"
    handle_subscribe(data)
  when "message"
    handle_message(data)
  when "ping"
    send({type: "pong"}.to_json)
  end
end
```

### Client Protocol

```javascript
const ws = new WebSocket('ws://localhost:4000/chat');

ws.onopen = () => {
  ws.send(JSON.stringify({
    type: 'subscribe',
    room: 'general'
  }));
};

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  handleMessage(data);
};
```

## Common Patterns

### Room-Based Channels

Organize connections into rooms:

```crystal
class RoomChannel < Azu::Channel
  PATH = "/rooms/:room_id"

  @@rooms = Hash(String, Set(HTTP::WebSocket)).new { |h, k|
    h[k] = Set(HTTP::WebSocket).new
  }

  def on_connect
    room = params["room_id"]
    @@rooms[room] << socket
  end

  def on_message(message)
    room = params["room_id"]
    broadcast_to_room(room, message)
  end

  def on_close(code, reason)
    room = params["room_id"]
    @@rooms[room].delete(socket)
  end

  private def broadcast_to_room(room, message)
    @@rooms[room].each { |ws| ws.send(message) }
  end
end
```

### User-Targeted Messages

Associate connections with users:

```crystal
class UserChannel < Azu::Channel
  @@user_sockets = Hash(Int64, Set(HTTP::WebSocket)).new { |h, k|
    h[k] = Set(HTTP::WebSocket).new
  }

  def on_connect
    if user = authenticate
      @@user_sockets[user.id] << socket
    end
  end

  def self.send_to_user(user_id : Int64, message : String)
    @@user_sockets[user_id].each { |ws| ws.send(message) }
  end
end

# From anywhere in your app:
UserChannel.send_to_user(user.id, notification.to_json)
```

### Presence Tracking

Track who's online:

```crystal
class PresenceChannel < Azu::Channel
  @@online_users = Set(Int64).new

  def on_connect
    if user = authenticate
      @@online_users << user.id
      broadcast_presence_update
    end
  end

  def on_close(code, reason)
    if user = @current_user
      @@online_users.delete(user.id)
      broadcast_presence_update
    end
  end

  def self.online?(user_id : Int64)
    @@online_users.includes?(user_id)
  end
end
```

## Authentication

WebSocket connections can be authenticated:

```crystal
def on_connect
  token = context.request.query_params["token"]?

  if token && (user = validate_token(token))
    @current_user = user
    send({type: "authenticated"}.to_json)
  else
    send({type: "error", message: "Unauthorized"}.to_json)
    socket.close
  end
end
```

Client-side:
```javascript
const token = getAuthToken();
const ws = new WebSocket(`ws://localhost:4000/channel?token=${token}`);
```

## Scaling Considerations

### Single Server

On a single server, channel state is in-memory:

```crystal
@@connections = [] of HTTP::WebSocket
```

### Multiple Servers

For multiple servers, use Redis pub/sub:

```crystal
class ScalableChannel < Azu::Channel
  @@redis = Redis.new

  def on_connect
    spawn do
      @@redis.subscribe("channel:messages") do |on|
        on.message do |_, msg|
          socket.send(msg)
        end
      end
    end
  end

  def self.broadcast(message)
    @@redis.publish("channel:messages", message)
  end
end
```

## Error Handling

Handle connection errors gracefully:

```crystal
def on_message(message)
  process(message)
rescue JSON::ParseException
  send({type: "error", code: "INVALID_JSON"}.to_json)
rescue ex
  Log.error { "Channel error: #{ex.message}" }
  send({type: "error", code: "INTERNAL_ERROR"}.to_json)
end
```

## See Also

- [Components](components.md)
- [Channel Reference](../../reference/api/channel.md)
- [How to Create WebSocket Channel](../../how-to/real-time/create-websocket-channel.md)

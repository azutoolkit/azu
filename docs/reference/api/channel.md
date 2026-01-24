# Channel Reference

Channels handle WebSocket connections for real-time communication.

## Extending Channel

```crystal
class MyChannel < Azu::Channel
  PATH = "/ws/path"

  def on_connect
    # Handle connection
  end

  def on_message(message : String)
    # Handle message
  end

  def on_close(code, reason)
    # Handle disconnection
  end
end
```

## Class Constants

### PATH

Define the WebSocket endpoint path.

```crystal
PATH = "/notifications"
PATH = "/chat/:room_id"
```

## Lifecycle Methods

### on_connect

Called when a client connects.

```crystal
def on_connect
  # Initialize connection
  # Authenticate user
  # Join rooms
end
```

### on_message

Called when a message is received.

```crystal
def on_message(message : String)
  data = JSON.parse(message)
  # Process message
end
```

**Parameters:**
- `message : String` - Raw message from client

### on_close

Called when connection closes.

```crystal
def on_close(code : Int32?, reason : String?)
  # Cleanup resources
  # Remove from rooms
end
```

**Parameters:**
- `code : Int32?` - Close code
- `reason : String?` - Close reason

### on_error

Called on WebSocket error.

```crystal
def on_error(error : Exception)
  Log.error { "WebSocket error: #{error.message}" }
end
```

## Instance Methods

### socket

Access the WebSocket instance.

```crystal
def on_connect
  socket.object_id  # Unique identifier
end
```

**Returns:** `HTTP::WebSocket`

### send

Send a message to the connected client.

```crystal
def on_connect
  send({type: "welcome", message: "Hello!"}.to_json)
end
```

**Parameters:**
- `message : String` - Message to send

### close

Close the WebSocket connection.

```crystal
def on_message(message : String)
  if invalid_message?(message)
    close(code: 4000, reason: "Invalid message")
  end
end
```

**Parameters:**
- `code : Int32?` - Close code
- `reason : String?` - Close reason

### context

Access the HTTP context.

```crystal
def on_connect
  context.request.query_params["token"]?
end
```

**Returns:** `HTTP::Server::Context`

### params

Access route parameters.

```crystal
# PATH = "/rooms/:room_id"

def on_connect
  room_id = params["room_id"]
end
```

**Returns:** `Hash(String, String)`

### headers

Access request headers.

```crystal
def on_connect
  auth = headers["Authorization"]?
end
```

**Returns:** `HTTP::Headers`

## Broadcasting

### Class-level broadcasting

```crystal
class NotificationChannel < Azu::Channel
  CONNECTIONS = [] of HTTP::WebSocket

  def on_connect
    CONNECTIONS << socket
  end

  def on_close(code, reason)
    CONNECTIONS.delete(socket)
  end

  def self.broadcast(message : String)
    CONNECTIONS.each(&.send(message))
  end
end
```

### Broadcast to others

```crystal
def broadcast(message : String, except : HTTP::WebSocket? = nil)
  CONNECTIONS.each do |ws|
    ws.send(message) unless ws == except
  end
end
```

## Room Management

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

  def self.room_count(room_id : String) : Int32
    @@rooms[room_id].size
  end
end
```

## Authentication

```crystal
class SecureChannel < Azu::Channel
  PATH = "/secure"

  @user : User?

  def on_connect
    token = context.request.query_params["token"]?

    unless token && (@user = authenticate(token))
      send({type: "error", message: "Unauthorized"}.to_json)
      close(code: 4001, reason: "Unauthorized")
      return
    end

    send({type: "authenticated", user: @user.not_nil!.name}.to_json)
  end

  private def authenticate(token : String) : User?
    Token.validate(token)
  end
end
```

## Message Handling Pattern

```crystal
def on_message(message : String)
  data = JSON.parse(message)

  case data["type"]?.try(&.as_s)
  when "ping"
    handle_ping
  when "subscribe"
    handle_subscribe(data)
  when "message"
    handle_message(data)
  else
    send({type: "error", message: "Unknown type"}.to_json)
  end
rescue JSON::ParseException
  send({type: "error", message: "Invalid JSON"}.to_json)
end

private def handle_ping
  send({type: "pong", timestamp: Time.utc.to_unix}.to_json)
end
```

## Complete Example

```crystal
class ChatChannel < Azu::Channel
  PATH = "/chat/:room"

  @@rooms = Hash(String, Array(HTTP::WebSocket)).new { |h, k| h[k] = [] of HTTP::WebSocket }

  def on_connect
    room = params["room"]
    @@rooms[room] << socket

    broadcast_to_room(room, {
      type: "system",
      message: "User joined",
      users: @@rooms[room].size
    }.to_json)
  end

  def on_message(message : String)
    room = params["room"]
    broadcast_to_room(room, message, except: socket)
  end

  def on_close(code, reason)
    room = params["room"]
    @@rooms[room].delete(socket)

    broadcast_to_room(room, {
      type: "system",
      message: "User left",
      users: @@rooms[room].size
    }.to_json)
  end

  private def broadcast_to_room(room : String, message : String, except : HTTP::WebSocket? = nil)
    @@rooms[room].each do |ws|
      ws.send(message) unless ws == except
    end
  end
end
```

## See Also

- [Component Reference](component.md)
- [How to Create WebSocket Channel](../../how-to/real-time/create-websocket-channel.md)

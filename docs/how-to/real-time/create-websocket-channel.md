# How to Create a WebSocket Channel

This guide shows you how to create WebSocket channels for real-time communication.

## Basic Channel

Create a channel by extending `Azu::Channel`:

```crystal
class ChatChannel < Azu::Channel
  PATH = "/chat"

  def on_connect
    # Called when client connects
    send({type: "connected", message: "Welcome!"}.to_json)
  end

  def on_message(message : String)
    # Called when client sends a message
    data = JSON.parse(message)
    # Process message...
  end

  def on_close(code, reason)
    # Called when connection closes
  end
end
```

## Register the Channel

Add your channel to the application:

```crystal
MyApp.start [
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  ChatChannel.new,
  # ... other handlers
]
```

## Client Connection

Connect from JavaScript:

```javascript
const socket = new WebSocket('ws://localhost:4000/chat');

socket.onopen = () => {
  console.log('Connected');
};

socket.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log('Received:', data);
};

socket.onclose = () => {
  console.log('Disconnected');
};

// Send a message
socket.send(JSON.stringify({
  type: 'message',
  content: 'Hello!'
}));
```

## Handling Different Message Types

```crystal
class ChatChannel < Azu::Channel
  PATH = "/chat"

  def on_message(message : String)
    data = JSON.parse(message)

    case data["type"]?.try(&.as_s)
    when "message"
      handle_chat_message(data)
    when "typing"
      handle_typing_indicator(data)
    when "ping"
      send({type: "pong"}.to_json)
    else
      send({type: "error", message: "Unknown message type"}.to_json)
    end
  rescue JSON::ParseException
    send({type: "error", message: "Invalid JSON"}.to_json)
  end

  private def handle_chat_message(data)
    content = data["content"]?.try(&.as_s) || ""
    # Process chat message...
  end

  private def handle_typing_indicator(data)
    # Handle typing indicator...
  end
end
```

## Connection State

Track connection state:

```crystal
class ChatChannel < Azu::Channel
  PATH = "/chat"

  CONNECTIONS = [] of HTTP::WebSocket

  def on_connect
    CONNECTIONS << socket
    broadcast_user_count
  end

  def on_close(code, reason)
    CONNECTIONS.delete(socket)
    broadcast_user_count
  end

  private def broadcast_user_count
    message = {type: "users", count: CONNECTIONS.size}.to_json
    CONNECTIONS.each(&.send(message))
  end
end
```

## Authentication

Authenticate WebSocket connections:

```crystal
class AuthenticatedChannel < Azu::Channel
  PATH = "/secure"

  @user : User?

  def on_connect
    token = context.request.query_params["token"]?

    if token && (user = authenticate(token))
      @user = user
      send({type: "authenticated", user: user.name}.to_json)
    else
      send({type: "error", message: "Unauthorized"}.to_json)
      socket.close
    end
  end

  private def authenticate(token : String) : User?
    # Validate token and return user
    Token.validate(token)
  end
end
```

## Room-based Channels

Create channels with rooms:

```crystal
class RoomChannel < Azu::Channel
  PATH = "/rooms/:room_id"

  @@rooms = Hash(String, Array(HTTP::WebSocket)).new { |h, k| h[k] = [] of HTTP::WebSocket }

  def on_connect
    room_id = params["room_id"]
    @@rooms[room_id] << socket
    broadcast_to_room(room_id, {type: "joined", room: room_id}.to_json)
  end

  def on_message(message : String)
    room_id = params["room_id"]
    broadcast_to_room(room_id, message)
  end

  def on_close(code, reason)
    room_id = params["room_id"]
    @@rooms[room_id].delete(socket)
  end

  private def broadcast_to_room(room_id : String, message : String)
    @@rooms[room_id].each do |ws|
      ws.send(message) unless ws == socket
    end
  end
end
```

## Error Handling

Handle errors gracefully:

```crystal
class ChatChannel < Azu::Channel
  PATH = "/chat"

  def on_message(message : String)
    process_message(message)
  rescue ex : JSON::ParseException
    send({type: "error", code: "INVALID_JSON"}.to_json)
  rescue ex : Exception
    Log.error { "WebSocket error: #{ex.message}" }
    send({type: "error", code: "INTERNAL_ERROR"}.to_json)
  end
end
```

## See Also

- [Broadcast Messages](broadcast-messages.md)
- [Build Live Component](build-live-component.md)

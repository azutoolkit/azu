# Adding WebSockets

This tutorial teaches you how to add real-time features to your Azu application using WebSocket channels.

## What You'll Build

By the end of this tutorial, you'll have:

- A WebSocket channel for real-time notifications
- Broadcasting messages to connected clients
- Client-side WebSocket connection handling
- Understanding of the channel lifecycle

## Prerequisites

- Completed [Building a User API](building-a-user-api.md) tutorial
- Basic understanding of WebSockets

## Step 1: Understanding WebSocket Channels

WebSocket channels in Azu provide:

- **Persistent connections** - Clients stay connected for real-time updates
- **Bidirectional communication** - Both server and client can send messages
- **Broadcasting** - Send messages to all connected clients
- **Lifecycle events** - Handle connect, message, and disconnect events

## Step 2: Create a Notification Channel

Create `src/channels/notification_channel.cr`:

```crystal
class NotificationChannel < Azu::Channel
  CONNECTIONS = Set(HTTP::WebSocket).new

  ws "/notifications"

  def on_connect
    # Add socket to connections
    CONNECTIONS << socket.not_nil!

    # Send welcome message
    send_to_client({
      type: "connected",
      message: "Connected to notifications",
      timestamp: Time.utc.to_rfc3339
    })

    Log.info { "Client connected. Total: #{CONNECTIONS.size}" }
  end

  def on_message(message : String)
    begin
      data = JSON.parse(message)
      handle_message(data)
    rescue JSON::ParseException
      send_to_client({type: "error", message: "Invalid JSON"})
    end
  end

  def on_close(code, message)
    CONNECTIONS.delete(socket)
    Log.info { "Client disconnected. Total: #{CONNECTIONS.size}" }
  end

  private def handle_message(data : JSON::Any)
    case data["type"]?.try(&.as_s)
    when "ping"
      send_to_client({type: "pong", timestamp: Time.utc.to_rfc3339})
    when "subscribe"
      send_to_client({type: "subscribed", message: "Subscribed to notifications"})
    else
      send_to_client({type: "error", message: "Unknown message type"})
    end
  end

  private def send_to_client(data)
    socket.not_nil!.send(data.to_json)
  end

  # Broadcast to all connected clients
  def self.broadcast(message)
    CONNECTIONS.each do |socket|
      spawn socket.send(message.to_json)
    end
  end
end
```

## Step 3: Add Broadcasting to Your API

Update `src/endpoints/create_user_endpoint.cr` to broadcast when users are created:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    unless create_user_request.valid?
      raise Azu::Response::ValidationError.new(
        create_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
      )
    end

    if User.find_by_email(create_user_request.email)
      raise Azu::Response::ValidationError.new(
        {"email" => ["Email is already taken"]}
      )
    end

    user = User.new(
      name: create_user_request.name,
      email: create_user_request.email,
      age: create_user_request.age
    )

    # Broadcast to all WebSocket clients
    NotificationChannel.broadcast({
      type: "user_created",
      user: {
        id: user.id,
        name: user.name,
        email: user.email
      },
      timestamp: Time.utc.to_rfc3339
    })

    status 201
    UserResponse.new(user)
  end
end
```

Similarly update delete and update endpoints to broadcast their events.

## Step 4: Update the Main Application

Update `src/user_api.cr` to include the channel:

```crystal
require "azu"

require "./models/*"
require "./requests/*"
require "./responses/*"
require "./endpoints/*"
require "./channels/*"

module UserAPI
  include Azu

  configure do
    port = ENV.fetch("PORT", "4000").to_i
    host = ENV.fetch("HOST", "0.0.0.0")
  end
end

UserAPI.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  Azu::Handler::CORS.new,
  NotificationChannel.new,  # Add the channel
  ListUsersEndpoint.new,
  ShowUserEndpoint.new,
  CreateUserEndpoint.new,
  UpdateUserEndpoint.new,
  DeleteUserEndpoint.new,
]
```

## Step 5: Create a Client Page

Create `public/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Real-time Notifications</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 20px; }
    #notifications {
      border: 1px solid #ddd;
      padding: 10px;
      margin: 20px 0;
      max-height: 300px;
      overflow-y: auto;
    }
    .notification {
      padding: 5px;
      border-bottom: 1px solid #eee;
    }
    .connected { color: green; }
    .disconnected { color: red; }
  </style>
</head>
<body>
  <h1>Real-time Notifications</h1>

  <div id="status" class="disconnected">Disconnected</div>

  <div id="notifications">
    <h3>Events</h3>
  </div>

  <script>
    const statusEl = document.getElementById('status');
    const notificationsEl = document.getElementById('notifications');

    // Connect to WebSocket
    const ws = new WebSocket('ws://localhost:4000/notifications');

    ws.onopen = function() {
      statusEl.textContent = 'Connected';
      statusEl.className = 'connected';

      // Subscribe to notifications
      ws.send(JSON.stringify({ type: 'subscribe' }));
    };

    ws.onmessage = function(event) {
      const data = JSON.parse(event.data);
      addNotification(data);
    };

    ws.onclose = function() {
      statusEl.textContent = 'Disconnected';
      statusEl.className = 'disconnected';
    };

    function addNotification(data) {
      const div = document.createElement('div');
      div.className = 'notification';

      const time = new Date().toLocaleTimeString();

      switch(data.type) {
        case 'user_created':
          div.textContent = `${time}: User created - ${data.user.name}`;
          break;
        case 'user_updated':
          div.textContent = `${time}: User updated - ${data.user.name}`;
          break;
        case 'user_deleted':
          div.textContent = `${time}: User deleted - ID ${data.user_id}`;
          break;
        case 'connected':
        case 'subscribed':
          div.textContent = `${time}: ${data.message}`;
          break;
        default:
          div.textContent = `${time}: ${JSON.stringify(data)}`;
      }

      notificationsEl.appendChild(div);
    }
  </script>
</body>
</html>
```

## Step 6: Add Static File Handler

Update your application to serve static files:

```crystal
UserAPI.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  Azu::Handler::CORS.new,
  Azu::Handler::Static.new("public"),  # Serve static files
  NotificationChannel.new,
  # ... endpoints
]
```

## Step 7: Test Real-time Updates

1. Start the server:
   ```bash
   crystal run src/user_api.cr
   ```

2. Open `http://localhost:4000/` in your browser

3. In another terminal, create a user:
   ```bash
   curl -X POST http://localhost:4000/users \
     -H "Content-Type: application/json" \
     -d '{"name": "Test User", "email": "test@example.com"}'
   ```

4. Watch the notification appear in your browser in real-time!

## Creating a Chat Room

For room-based broadcasting, use a message-based room join pattern:

```crystal
class ChatChannel < Azu::Channel
  @@rooms = Hash(String, Set(HTTP::WebSocket)).new { |h, k| h[k] = Set(HTTP::WebSocket).new }
  @@socket_rooms = Hash(HTTP::WebSocket, String).new

  ws "/chat"

  def on_connect
    send_to_client({
      type: "connected",
      message: "Send a 'join' message with room_id to join a room"
    })
  end

  def on_message(message : String)
    data = JSON.parse(message)

    case data["type"]?.try(&.as_s)
    when "join"
      handle_join(data)
    when "message"
      handle_chat_message(data)
    end
  rescue
    send_to_client({type: "error", message: "Invalid message"})
  end

  def on_close(code, message)
    if room_id = @@socket_rooms[socket]?
      @@rooms[room_id].delete(socket)
      @@socket_rooms.delete(socket)
    end
  end

  private def handle_join(data)
    room_id = data["room_id"]?.try(&.as_s)
    return send_to_client({type: "error", message: "room_id required"}) unless room_id

    @@socket_rooms[socket] = room_id
    @@rooms[room_id] << socket

    send_to_client({type: "joined", room_id: room_id})

    # Notify others in room
    broadcast_to_room(room_id, {
      type: "user_joined",
      message: "A user joined the room"
    }, exclude: socket)
  end

  private def handle_chat_message(data)
    room_id = @@socket_rooms[socket]?
    return send_to_client({type: "error", message: "Not in a room"}) unless room_id

    message = data["message"]?.try(&.as_s)
    return send_to_client({type: "error", message: "Message required"}) unless message

    broadcast_to_room(room_id, {
      type: "chat_message",
      message: message,
      timestamp: Time.utc.to_rfc3339
    })
  end

  private def broadcast_to_room(room_id : String, data, exclude : HTTP::WebSocket? = nil)
    message = data.to_json
    @@rooms[room_id].each do |connection|
      next if connection == exclude
      spawn { connection.send(message) }
    end
  end

  private def send_to_client(data)
    socket.send(data.to_json)
  end
end
```

## Key Concepts Learned

### Channel Lifecycle

```crystal
def on_connect    # Called when client connects
def on_message    # Called when message received
def on_close      # Called when client disconnects
```

### Broadcasting Patterns

```crystal
# To all clients
CONNECTIONS.each { |s| spawn s.send(msg) }

# To specific room
@@rooms[room_id].each { |s| spawn s.send(msg) }

# Exclude sender
next if connection == exclude
```

### Message Protocol

Use a `type` field to route messages:
```json
{"type": "join", "room_id": "general"}
{"type": "message", "content": "Hello!"}
```

## Next Steps

You've added real-time features to your API. Continue learning with:

- [Working with Databases](working-with-databases.md) - Persist data to PostgreSQL
- [Building Live Components](building-live-components.md) - Create reactive UI components
- [Testing Your App](testing-your-app.md) - Test your WebSocket channels

---

**Real-time features unlocked!** Your application now supports live updates via WebSockets.

# Adding WebSockets

This tutorial teaches you how to add real-time features to your Azu application using WebSocket channels.

## What You'll Build

By the end of this tutorial, you'll have:

- A WebSocket channel for real-time notifications
- Broadcasting from an endpoint to every connected client
- A browser page that receives the notifications
- A chat channel with rooms
- Understanding of the channel lifecycle

## Prerequisites

- Completed [Building a User API](building-a-user-api.md) tutorial (the `POST /users` endpoint below is a
  slimmed-down version of the one you wrote there)
- Crystal 1.19.1 or newer
- Basic understanding of WebSockets

## Step 1: Understanding WebSocket Channels

An HTTP request is answered and forgotten. A WebSocket stays open, so the server can push messages
whenever something happens. In Azu a **channel** handles one connection:

- Azu creates a new channel instance for every client that connects.
- `on_connect`, `on_message`, `on_binary`, `on_ping`, `on_pong` and `on_close` are called for the
  events of that connection. All six are abstract, so a channel has to implement them.
- `send` writes to this client. `subscribe` and `broadcast` use a **topic**: everything broadcast to a
  topic reaches every connection subscribed to it (see `Azu::PubSub`).

## Step 2: Create a Notification Channel

Create `src/channels/notification_channel.cr`:

```crystal
class NotificationChannel < Azu::Channel
  ws "/notifications"

  def on_connect
    subscribe "notifications"
    send({type: "connected", message: "Listening for notifications"}.to_json)
  end

  def on_message(message : String)
    # Clients only listen on this channel; ignore what they send.
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
```

`ws "/notifications"` registers the route when the class is defined. Because the channel subscribes to
the `notifications` topic, it receives every message broadcast to it, and Azu releases the subscription
when the connection closes.

## Step 3: Add Broadcasting to Your API

Any code can broadcast to the topic. Here a `POST /users` endpoint announces every user it creates.

Create `src/endpoints/create_user_endpoint.cr`:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  validate name, presence: true, size: 2..50
  validate email, presence: true, match: /@/
end

struct CreatedUserResponse
  include Azu::Response

  def initialize(@name : String, @email : String)
  end

  def render
    {name: @name, email: @email}.to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, CreatedUserResponse)

  post "/users"

  def call : CreatedUserResponse
    user = create_user_request

    Azu::PubSub.broadcast("notifications", {
      type:    "user_created",
      message: "#{user.name} just signed up",
      at:      Time.utc.to_rfc3339,
    })

    status 201
    content_type "application/json"
    CreatedUserResponse.new(user.name, user.email)
  end
end
```

A request that fails validation never reaches `call`: Azu answers `422` with the validation errors, so
nothing is broadcast for bad input. `Azu::PubSub.broadcast` encodes a non-string payload as JSON.

## Step 4: Update the Main Application

Channels and endpoints register themselves with the router when they are defined, so the application
only has to load their files and start. In `src/user_api.cr`, add `require "./channels/*"` next to the
other requires, then:

```crystal
require "azu"

module UserAPI
  include Azu
end

# Same default stack as Azu.start: request id, logging, error pages, security headers and static files
UserAPI.start
```

`UserAPI.start` without arguments uses the default handler stack, which already serves files from
`public/` (the next step) and falls through to the router for everything else. Azu reads `PORT` (4000 by
default) and `HOST` (`127.0.0.1` in development, `0.0.0.0` in other environments) from the environment.

## Step 5: Create a Client Page

Create `public/index.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <title>Notifications</title>
</head>
<body>
  <h1>Notifications</h1>
  <p id="status">connecting...</p>
  <ul id="notifications"></ul>

  <script>
    const status = document.getElementById("status");
    const list = document.getElementById("notifications");
    const scheme = location.protocol === "https:" ? "wss" : "ws";

    function connect() {
      const socket = new WebSocket(`${scheme}://${location.host}/notifications`);

      socket.onopen = () => (status.textContent = "connected");
      socket.onclose = () => {
        status.textContent = "disconnected, retrying...";
        setTimeout(connect, 2000);
      };
      socket.onmessage = (event) => {
        const data = JSON.parse(event.data);
        if (data.type !== "user_created") return;
        const item = document.createElement("li");
        item.textContent = data.message; // textContent, never innerHTML, for server data
        list.prepend(item);
      };
    }

    connect();
  </script>
</body>
</html>
```

The page opens its own origin, which is what Azu's origin check accepts. To allow a page served from
another origin, list it in `Azu::CONFIG.websocket.allowed_origins`.

## Step 6: Serve the Page

The default stack's static handler serves `public/index.html` for `/`. Nothing to add. If you pass your
own handler array to `start`, include `Azu::Handler::Static.new`: it serves the files and passes everything
else on to the router (`fallthrough` is `true` by default):

```crystal
require "azu"

module UserAPI
  include Azu
end

UserAPI.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Static.new,
] of HTTP::Handler
```

## Step 7: Test Real-time Updates

1. Start the server:

   ```bash
   crystal run src/user_api.cr
   ```

2. Open `http://localhost:4000/` in your browser; the status shows "connected".

3. In another terminal, create a user:

   ```bash
   curl -X POST http://localhost:4000/users \
     -H "Content-Type: application/json" \
     -d '{"name": "Test User", "email": "test@example.com"}'
   ```

4. The notification appears in the browser as soon as the request returns.

## Creating a Chat Room

For rooms, make the room part of the URL and the topic. Create `src/channels/chat_channel.cr`:

```crystal
class ChatChannel < Azu::Channel
  ws "/chat/:room"

  getter id = Random::Secure.hex(4)

  def on_connect
    subscribe topic
    send({type: "connected", room: room, you: id}.to_json)
    broadcast topic, {type: "joined", user: id}.to_json
  end

  def on_message(message : String)
    text = message.strip
    return send({type: "error", message: "empty message"}.to_json) if text.empty?
    broadcast topic, {type: "message", user: id, text: text[0, 500], at: Time.utc.to_rfc3339}.to_json
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
    broadcast topic, {type: "left", user: id}.to_json
  end

  private def room : String
    context.request.path_params["room"]
  end

  private def topic : String
    "chat:#{room}"
  end
end
```

- Two clients on `/chat/general` talk to each other; a client on `/chat/random` hears nothing of it.
- The sender receives its own message too, which keeps every client's view identical. A client that
  wants to skip its own messages compares `user` with the `you` it got on connect.
- `on_close` can still broadcast: the connection's own subscription is already gone, so only the
  others hear that the user left.

A client can try it with any WebSocket tool, or from Crystal:

```crystal
require "http/web_socket"

socket = HTTP::WebSocket.new("localhost", "/chat/general", 4000)
socket.on_message { |message| puts message }
spawn { socket.run }

socket.send "hello room"
sleep 200.milliseconds
socket.close
```

## Next Steps

- [Working with Databases](working-with-databases.md) - Persist data
- [Building Live Components](building-live-components.md) - Server-rendered UI that updates live
- [Testing Your App](testing-your-app.md) - Test your WebSocket channels

# Create a WebSocket channel

This guide shows how to accept WebSocket connections with `Azu::Channel`.

## Basic channel

A channel implements six callbacks, all abstract. Azu creates one instance per connection.

```crystal
class EchoChannel < Azu::Channel
  ws "/echo"

  def on_connect
    send({type: "welcome"}.to_json)
  end

  def on_message(message : String)
    send({type: "echo", body: message}.to_json)
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

`ws "/echo"` registers the channel on the application's router. The route is added to
`Azu::CONFIG.router` when the class is defined, so declaring the class is enough.

## Register the channel on an app

When you build apps as values, register the route with the route builder instead of the `ws` macro:

```crystal
class PingChannel < Azu::Channel
  def on_connect
  end

  def on_message(message : String)
    send "pong" if message == "ping"
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

app = Azu::App.new
app.routes do
  ws "/ping", PingChannel
end
```

## Connect a client

From a browser:

```javascript
const socket = new WebSocket("ws://localhost:3000/echo");

socket.onopen = () => socket.send("hello");
socket.onmessage = (event) => console.log(JSON.parse(event.data));
socket.onclose = (event) => console.log("closed", event.code, event.reason);
```

From Crystal, for a script or a test, use `HTTP::WebSocket`:

```crystal
require "http/web_socket"

socket = HTTP::WebSocket.new("localhost", "/echo", 3000)
socket.on_message { |message| puts message }
spawn { socket.run }

socket.send "hello"
sleep 100.milliseconds
socket.close
```

A browser sends an `Origin` header and Azu refuses the upgrade (403) unless it is the application's own
origin or listed in `Azu::CONFIG.websocket.allowed_origins`. Clients without an `Origin` header, such as
the Crystal client above, are accepted.

## Handle different message types

Parse every message into a type so that invalid input is rejected in one place:

```crystal
struct Command
  include JSON::Serializable

  getter type : String
  getter name : String?
end

class CommandChannel < Azu::Channel
  def on_connect
  end

  def on_message(message : String)
    command = Command.from_json(message)
    case command.type
    when "ping"
      send({type: "pong", at: Time.utc.to_unix}.to_json)
    when "greet"
      send({type: "greeting", text: "Hello, #{command.name || "stranger"}!"}.to_json)
    else
      send({type: "error", message: "unknown command #{command.type}"}.to_json)
    end
  rescue JSON::ParseException | JSON::SerializableError
    send({type: "error", message: "invalid message"}.to_json)
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

## Connection state

Because every connection has its own instance, per-connection state is a plain instance variable:

```crystal
class CounterChannel < Azu::Channel
  @messages = 0
  @joined_at = Time.utc

  def on_connect
    @joined_at = Time.utc
    send "connected"
  end

  def on_message(message : String)
    @messages += 1
    send({messages: @messages, seconds: (Time.utc - @joined_at).total_seconds.to_i}.to_json)
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
    Log.info { "closed after #{@messages} messages (#{code})" }
  end
end
```

A list of everyone online is [`Azu::Presence`](../../reference/api/presence.md#channels): include
`Azu::Presence::Tracked` in the channel. Other state shared between connections lives in a class-level
variable guarded by a `Mutex`; see [Broadcast Messages](broadcast-messages.md) for topics, which avoid most
of that.

## Query parameters, headers and path parameters

`params` is the query string of the upgrade request, `headers` its headers and `context` the whole
`HTTP::Server::Context`. Path parameters of the route are on the request.

```crystal
class InfoChannel < Azu::Channel
  def on_connect
    room = context.request.path_params["room"]
    send({room: room, name: params["name"]?, agent: headers["User-Agent"]?}.to_json)
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

app = Azu::App.new
app.routes { ws "/info/:room", InfoChannel }
```

## Authentication

Browsers cannot set headers on a WebSocket, so pass a token in the query string or rely on the cookies
the browser sends with the upgrade request. Check it in `on_connect` and close the connection if it is
not valid:

```crystal
require "crypto/subtle"

class PrivateChannel < Azu::Channel
  @user : String?

  def on_connect
    user = authenticate(params["token"]?)
    unless user
      send({type: "error", message: "Unauthorized"}.to_json)
      close(HTTP::WebSocket::CloseCode::PolicyViolation, "Unauthorized")
      return
    end
    @user = user
    send({type: "authenticated", user: user}.to_json)
  end

  def on_message(message : String)
    return unless user = @user
    send({from: user, echo: message}.to_json)
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end

  # Replace with a real check: a signed token, a session lookup, ...
  private def authenticate(token : String?) : String?
    expected = ENV["CHANNEL_TOKEN"]?
    return nil if token.nil? || expected.nil? || expected.empty?
    "alice" if Crypto::Subtle.constant_time_compare(token, expected)
  end
end
```

`authenticate` refuses every connection while `CHANNEL_TOKEN` is unset, and compares in constant time so the
response time does not reveal how much of the token matched. `on_message` checks `@user` again because a
client can send frames before the close handshake completes.

## Rooms

A room is a PubSub topic. Subscribe in `on_connect` and broadcast to the topic:

```crystal
class RoomChannel < Azu::Channel
  def on_connect
    subscribe topic
  end

  def on_message(message : String)
    broadcast topic, message
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end

  private def topic : String
    "room:#{context.request.path_params["room"]}"
  end
end

app = Azu::App.new
app.routes { ws "/rooms/:room", RoomChannel }
```

Every subscriber receives the broadcast, the sender included. The subscription ends when the connection
closes; there is nothing to clean up in `on_close`.

## Error handling

An exception that escapes a callback ends that connection. Rescue what you can recover from and tell the
client:

```crystal
class SafeChannel < Azu::Channel
  def on_connect
  end

  def on_message(message : String)
    send(process(message))
  rescue ex : ArgumentError
    send({type: "error", message: ex.message}.to_json)
  rescue ex
    Log.error(exception: ex) { "channel failed" }
    close(HTTP::WebSocket::CloseCode::InternalServerError, "internal error")
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end

  private def process(message : String) : String
    raise ArgumentError.new("empty message") if message.empty?
    message.upcase
  end
end
```

## Limits

`Azu::CONFIG.websocket` holds the settings of every channel; override the class methods
`allowed_origins`, `max_message_size` and `ping_interval` to change them for one channel class.

```crystal
Azu::CONFIG.websocket.allowed_origins = ["https://app.example.com"]
Azu::CONFIG.websocket.max_message_size = 64 * 1024
Azu::CONFIG.websocket.ping_interval = 20.seconds
```

## See also

- [Broadcast Messages](broadcast-messages.md)
- [Build Live Component](build-live-component.md)
- [Channel Reference](../../reference/api/channel.md)
- [Testing WebSockets](../testing/test-websockets.md)

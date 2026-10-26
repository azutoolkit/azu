---
description: "Handle a WebSocket connection with `Azu::Channel`: callbacks, instance methods, origin checks, topics and shutdown."
---

# Channel

`Azu::Channel` handles one WebSocket connection. Azu builds a new instance for every client that connects, so
instance variables are per connection. It comes with `require "azu"`. A channel exchanges frames with one client;
messages between clients and processes go through topics of [`Azu::PubSub`](pubsub.md), and live server-rendered
views are [Spark components](component.md), not channels.

A channel implements six callbacks. All of them are abstract, so a channel that leaves one out does not compile.

<!-- prelude -->
```crystal
class EchoChannel < Azu::Channel
  ws "/echo"

  def on_connect
    send "connected"
  end

  def on_message(message : String)
    send "echo: #{message}"
  end

  def on_binary(binary : Bytes)
    send "received #{binary.size} bytes"
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end
end
```

## API

### Routes

`ws "/echo"` in the class body registers the channel on the global router (`Azu::CONFIG.router`). To register it on
a specific app, use the route builder instead:

```crystal
app = Azu::App.new
app.routes do
  ws "/echo", EchoChannel
  scope "/v2" do
    ws "/echo", EchoChannel # served at /v2/echo
  end
end
```

The route is a `Channel::Upgrader`: it validates the handshake and the `Origin` header, answers
`101 Switching Protocols` and hands the socket to a new channel instance.

### Callbacks

| Callback | When |
| --- | --- |
| `on_connect` | The handshake is done. `context`, `params` and `headers` are available. |
| `on_message(message : String)` | A text frame arrived. |
| `on_binary(binary : Bytes)` | A binary frame arrived. |
| `on_ping(message : String)` | The client sent a ping. The pong is answered automatically. |
| `on_pong(message : String)` | The client answered a ping. |
| `on_close(code, message)` | The client closed the connection, or it was lost. `code` is `HTTP::WebSocket::CloseCode?`. |
| `on_broadcast(message : PubSub::Message)` | A message was broadcast to a topic this channel subscribed to. Optional: the default sends the payload to the socket. |

{% hint style="warning" %}
An exception raised from a callback ends the connection; subscriptions are still released.
{% endhint %}

### Instance methods

| Method | Returns | Description |
| --- | --- | --- |
| `socket` | `HTTP::WebSocket` | The underlying socket. |
| `context` | `HTTP::Server::Context` | The upgrade request, available from `on_connect` on. |
| `params` | `HTTP::Params` | The query string of the upgrade request. |
| `headers` | `HTTP::Headers` | The headers of the upgrade request (`Origin`, cookies, ...). |
| `send(message : String)` | `Nil` | Writes a text frame. Safe to call from any fiber. |
| `send(bytes : Bytes)` | `Nil` | Writes a binary frame. Safe to call from any fiber. |
| `close(code = NormalClosure, message = nil)` | `Nil` | Sends a close frame. A socket that is already gone is ignored. |
| `subscribe(topic : String)` | `Nil` | Joins a PubSub topic; broadcasts reach `on_broadcast`. |
| `unsubscribe(topic : String)` | `Nil` | Leaves a topic. |
| `broadcast(topic : String, message : String)` | `Nil` | Publishes to every subscriber of the topic, in this process or in others when the PubSub backend is shared. |

Path parameters of the route (`ws "/rooms/:room", RoomChannel`) are on the upgrade request:

```crystal
class RoomChannel < Azu::Channel
  def on_connect
    room = context.request.path_params["room"]
    token = params["token"]? # ?token=... in the URL
    origin = headers["Origin"]?
    send "joined #{room} (token #{token ? "given" : "missing"}, origin #{origin || "none"})"
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
app.routes { ws "/rooms/:room", RoomChannel }
```

### Class-level settings

These class methods read the `websocket` options of the current configuration (see
[Configuration options](../configuration/options.md#websockets)) and can be overridden per channel class.

| Method | Default | Description |
| --- | --- | --- |
| `allowed_origins : Array(String)` | `websocket.allowed_origins` | Origins accepted besides the request's own origin; `"*"` accepts any. |
| `max_message_size : Int32` | `websocket.max_message_size` (1 MiB) | Larger frames close the connection with `CloseCode::MessageTooBig`. |
| `ping_interval : Time::Span?` | `websocket.ping_interval` (30 s) | Interval between server pings; `nil` disables them. |
| `origin_allowed?(request) : Bool` | | The check the upgrader runs. A request without `Origin` (a non-browser client) is accepted. |

```crystal
Azu::CONFIG.websocket.allowed_origins = ["https://app.example.com"]
Azu::CONFIG.websocket.max_message_size = 64 * 1024
Azu::CONFIG.websocket.ping_interval = 20.seconds
Azu::CONFIG.websocket.tcp_nodelay = true # the default: frames leave at once, no Nagle delay

class SmallMessagesChannel < Azu::Channel
  def self.max_message_size : Int32
    1024
  end

  def on_connect
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
```

## Behavior

### Origin check

A browser upgrade from a foreign origin is answered with `403` before the socket is created.
Behind a proxy that rewrites `Host`, list the public origin in `WEBSOCKET_ALLOWED_ORIGINS`.

### Closing and rejecting

`close` takes an `HTTP::WebSocket::CloseCode` (or an `Int`) and a reason. Use it to refuse a
connection you cannot authenticate. This channel refuses every connection while `CHANNEL_TOKEN` is unset, and
compares the token in constant time:

```crystal
require "crypto/subtle"

class SecureChannel < Azu::Channel
  def on_connect
    expected = ENV["CHANNEL_TOKEN"]?.presence
    given = params["token"]?
    unless expected && given && Crypto::Subtle.constant_time_compare(given, expected)
      close(HTTP::WebSocket::CloseCode::PolicyViolation, "Unauthorized")
      return
    end
    send "welcome"
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
```

### Topics

`subscribe`, `unsubscribe` and `broadcast` go through [`Azu::PubSub`](pubsub.md); subscriptions made with `subscribe`
end with the connection. For a list of who is connected, use [`Azu::Presence`](presence.md): include
`Azu::Presence::Tracked` in the channel, and what it tracks ends with the connection too (see
[Presence in channels](presence.md#channels)).

### Handling typed messages

```crystal
struct ChatMessage
  include JSON::Serializable

  getter type : String
  getter text : String?
end

class ChatChannel < Azu::Channel
  ws "/chat"

  def on_connect
    subscribe "chat"
  end

  def on_message(message : String)
    chat = ChatMessage.from_json(message)
    case chat.type
    when "say"
      broadcast "chat", {type: "say", text: chat.text}.to_json
    when "ping"
      send({type: "pong"}.to_json)
    else
      send({type: "error", message: "unknown type"}.to_json)
    end
  rescue JSON::ParseException | JSON::SerializableError
    send({type: "error", message: "invalid JSON"}.to_json)
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

### Shutdown

When the app shuts down (`SIGTERM`, `SIGINT`, `App#stop`) every open channel socket is sent a close frame
with code 1001 (going away) at once; `on_close` runs with the code the peer answers with (normally the same 1001), and the app waits for
that within `shutdown_timeout`. A socket that registers after shutdown began is closed without `on_connect`; one that registered just before still runs it and is then closed. `App#start` then
calls `Azu.shutdown`, which closes Spark connections and the PubSub backend. See [Shut down gracefully](../../how-to/deployment/graceful-shutdown.md).

## See also

- [PubSub](pubsub.md)
- [Component](component.md)
- [Create a WebSocket channel](../../how-to/real-time/create-websocket-channel.md)
- [Spark live views](../../explanation/spark-live-views.md)

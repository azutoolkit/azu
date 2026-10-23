# How to Broadcast Messages

Channels and Spark components exchange messages through topics of `Azu::PubSub`. This guide shows the
common broadcasting patterns.

## Basic broadcasting

A channel joins a topic with `subscribe`; everything broadcast to the topic reaches `on_broadcast`,
which writes the payload to the socket unless you override it.

```crystal
class NotificationChannel < Azu::Channel
  ws "/notifications"

  def on_connect
    subscribe "notifications"
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

Broadcast from anywhere in the application with `Azu::PubSub.broadcast`. A payload that is not a
`String` is encoded as JSON:

```crystal
Azu::PubSub.broadcast("notifications", "plain text")
Azu::PubSub.broadcast("notifications", {type: "notice", text: "Deploy finished"})
```

Subscriptions are released when the connection closes, so a channel has nothing to clean up.

## Broadcast from an endpoint

```crystal
struct AnnounceResponse
  include Azu::Response

  def render
    {sent: true}.to_json
  end
end

struct AnnounceEndpoint
  include Azu::Endpoint(Azu::Request, AnnounceResponse)

  post "/announce"

  def call : AnnounceResponse
    Azu::PubSub.broadcast("notifications", {type: "announcement", text: "Hello everyone"})
    content_type "application/json"
    AnnounceResponse.new
  end
end
```

## Rooms

A room is a topic whose name includes the room:

```crystal
class RoomChannel < Azu::Channel
  def on_connect
    subscribe topic
    broadcast topic, {type: "joined"}.to_json
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

A channel can be in several rooms at once: call `subscribe` for each and `unsubscribe` to leave.

## Skip the sender

A broadcast reaches every subscriber, the sender included. To skip the sender, put an identifier in the
payload and filter in `on_broadcast`, which runs for each message delivered to this connection:

```crystal
class ChatChannel < Azu::Channel
  getter id = Random::Secure.hex(4)

  def on_connect
    subscribe "chat"
  end

  def on_message(message : String)
    broadcast "chat", {from: id, text: message}.to_json
  end

  def on_broadcast(message : Azu::PubSub::Message) : Nil
    return if message.json(NamedTuple(from: String, text: String))[:from] == id
    send(message.payload)
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

## Messages to one user

Subscribe every connection to a topic that identifies its user, then broadcast to that topic from
anywhere, for example from a background job:

```crystal
class UserChannel < Azu::Channel
  def on_connect
    # Take the user from a verified token or session in a real application.
    subscribe "user:#{params["user_id"]?}"
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

module Notifier
  def self.notify(user_id : Int64, text : String) : Nil
    Azu::PubSub.broadcast("user:#{user_id}", {type: "notification", text: text})
  end
end

Notifier.notify(7_i64, "Your export is ready")
```

Because it only calls `Azu::PubSub.broadcast`, `Notifier.notify` works the same from an endpoint, a
fiber or a worker process (with the Redis backend, see below).

## Filtering per connection

Override `on_broadcast` to decide what a connection receives. Here a client picks the event kinds it
wants:

```crystal
class FilteredChannel < Azu::Channel
  @kinds = Set(String).new

  def on_connect
    subscribe "events"
  end

  def on_message(message : String)
    @kinds = message.split(',').map(&.strip).to_set
  end

  def on_broadcast(message : Azu::PubSub::Message) : Nil
    kind = message.json(NamedTuple(kind: String))[:kind]
    send(message.payload) if @kinds.empty? || @kinds.includes?(kind)
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

Azu::PubSub.broadcast("events", {kind: "order", id: 1})
```

## Broadcast from another fiber

`Azu::PubSub.broadcast` is safe to call from any fiber and `Channel#send` is guarded by a mutex, so a
background fiber can publish periodically:

```crystal
spawn(name: "clock") do
  loop do
    Azu::PubSub.broadcast("clock", {now: Time.utc.to_rfc3339})
    sleep 1.second
  end
end
```

Handlers run on the broadcaster's fiber, so a slow subscriber slows the broadcaster down. Keep
`on_broadcast` quick.

## Several servers

The default backend is in memory: a broadcast reaches the subscribers in the same process. Select the
Redis backend once at boot and every process receives every broadcast:

```crystal
Azu::PubSub.backend = Azu::PubSub::Redis.new(ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
```

Nothing connects until the first subscribe or broadcast, and the listener reconnects with backoff when
Redis goes away.

## Rate limiting

Azu does not throttle broadcasts for you. A small guard in front of the broadcast is enough to protect
subscribers from a noisy producer:

```crystal
class Throttled
  def initialize(@topic : String, @interval : Time::Span)
    @last = Time.instant - @interval
    @lock = Mutex.new
  end

  # Broadcasts unless the previous broadcast was less than the interval ago.
  def broadcast(payload : String) : Bool
    allowed = @lock.synchronize do
      now = Time.instant
      next false if now - @last < @interval
      @last = now
      true
    end
    Azu::PubSub.broadcast(@topic, payload) if allowed
    allowed
  end
end

prices = Throttled.new("prices", 250.milliseconds)
prices.broadcast({symbol: "CR", price: 41.5}.to_json)
```

## Batching

To send many small updates as one message, collect them and flush on an interval:

```crystal
class Batcher
  def initialize(@topic : String, @interval : Time::Span = 100.milliseconds)
    @pending = [] of String
    @lock = Mutex.new
    spawn(name: "batcher") do
      loop do
        sleep @interval
        flush
      end
    end
  end

  def push(item : String) : Nil
    @lock.synchronize { @pending << item }
  end

  private def flush : Nil
    items = @lock.synchronize { @pending.dup.tap { @pending.clear } }
    Azu::PubSub.broadcast(@topic, items) unless items.empty?
  end
end

batcher = Batcher.new("ticks")
batcher.push("a")
batcher.push("b")
```

## See also

- [Create a WebSocket channel](create-websocket-channel.md)
- [Build a live component](build-live-component.md)
- [Channel Reference](../../reference/api/channel.md)

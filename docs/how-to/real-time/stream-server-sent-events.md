---
description: Push a live feed from an endpoint to the browser with server-sent events, fed by `Azu::PubSub` and resumed after a reconnect.
---

# Stream server-sent events

Server-sent events are a one-way stream over an ordinary `GET`: the browser's `EventSource` opens it, hands each event
to your script and reconnects by itself when the connection drops. Use them for feeds, progress and notifications;
when the browser has to send messages too, use a [WebSocket channel](create-websocket-channel.md).

## Return an event stream

An endpoint whose response type is `Azu::Response::EventStream` streams events. The block runs in a fiber of its own
and sends events to the source it is given:

<!-- prelude -->
```crystal
struct TickerEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::EventStream)

  get "/ticker"

  def call : Azu::Response::EventStream
    Azu::Response::EventStream.new(retry: 3.seconds) do |events|
      events.send %({"symbol":"AZU","price":12.5}), event: "price", id: "1"
      events.send Azu::Response::EventStream::Event.json({symbol: "AZU", price: 12.75}, event: "price", id: "2")
      events.send "market\nclosed", event: "status"
    end
  end
end
```

`GET /ticker` answers `200` with `Content-Type: text/event-stream`, `Cache-Control: no-cache`,
`X-Accel-Buffering: no` and `Transfer-Encoding: chunked`, and this body, written and flushed one event at a time:

```text
retry: 3000

id: 1
event: price
data: {"symbol":"AZU","price":12.5}

id: 2
event: price
data: {"symbol":"AZU","price":12.75}

event: status
data: market
data: closed

```

- The stream opens with `retry: 3000` because the endpoint passes `retry:`: it tells the browser how long to wait
  before reconnecting, in milliseconds. Without it the stream opens with an empty comment line, `:`.
- `event:` names the event. The browser delivers a named event to `addEventListener("price", ...)`, and an event
  without a name to `onmessage`.
- `id:` is what the browser sends back when it reconnects.
- A line break in the data becomes a second `data:` line; the browser joins them with `\n` again.

{% hint style="info" %}
When the block returns, the response ends, and `EventSource` treats that like a dropped connection: it reconnects
after `retry` and the block runs again. To stop a client for good, send an event your page answers with
`source.close()`.
{% endhint %}

## Keep the connection open

After `heartbeat` without an event (15 seconds by default) Azu writes the comment `: heartbeat` followed by a blank
line. The browser ignores it, a proxy sees traffic and keeps the connection open, and a write to a client that has
left fails, which is how the stream notices the client is gone. Lower it when your proxy closes idle connections
sooner:

```crystal
Azu::Response::EventStream.new(heartbeat: 10.seconds) do |events|
  events.sleep 1.minute
end
```

While this block waits its minute, the client receives a heartbeat every 10 seconds.

nginx reads `X-Accel-Buffering: no` and does not buffer the stream. Any other proxy or load balancer in front of the
app needs response buffering off and an idle timeout longer than the heartbeat.

## Feed it from PubSub

Most streams forward what the rest of the app publishes. Subscribe to an `Azu::PubSub` topic inside the block and
forward its messages:

```crystal
struct PricesEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::EventStream)

  get "/prices"

  def call : Azu::Response::EventStream
    Azu::Response::EventStream.new do |events|
      inbox = ::Channel(Azu::PubSub::Message).new(64)
      subscription = Azu::PubSub.subscribe("prices") do |message|
        select
        when inbox.send(message)
        else # a slow client: drop the message rather than block the broadcaster
        end
      end

      begin
        events.forward(inbox) { |message| Azu::Response::EventStream::Event.new(message.payload, event: "price") }
      ensure
        subscription.cancel
      end
    end
  end
end
```

Publish from anywhere in the app, an endpoint or a job:

```crystal
Azu::PubSub.broadcast("prices", {symbol: "AZU", price: 12.5})
```

Every open `/prices` stream then writes:

```text
event: price
data: {"symbol":"AZU","price":12.5}

```

- A PubSub handler runs on the fiber that broadcasts, so it only puts the message in the stream's buffered channel.
  When a client reads slower than messages arrive and 64 are waiting, further messages are dropped for that client
  instead of holding up the broadcaster.
- `events.forward` sends one event per message until the stream ends; then `ensure` cancels the subscription. A
  client that disconnects is noticed at the next write, an event or a heartbeat, so its subscription is cancelled
  within two heartbeats.
- With the Redis backend (`Azu::PubSub.backend = Azu::PubSub::Redis.new(...)`), a broadcast from any process reaches
  the streams of every process (see [Scale horizontally](../deployment/scale-horizontally.md#real-time-across-processes)).

## Resume after a reconnect

When `EventSource` reconnects, it sends the `id` of the last event it received in the `Last-Event-ID` header. Azu
reads it for you (and `?lastEventId=` for clients that cannot set a header) as `events.last_event_id`. Send the events
the client missed, then continue:

<!-- prelude -->
```crystal
HISTORY = ["opened", "first trade", "second trade"]

struct HistoryEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::EventStream)

  get "/history"

  def call : Azu::Response::EventStream
    Azu::Response::EventStream.new do |events|
      seen = events.last_event_id.try(&.to_i?) || -1
      HISTORY.each_with_index do |text, index|
        next if index <= seen
        events.send text, id: index.to_s
      end
    end
  end
end
```

A reconnect with `Last-Event-ID: 1` receives only:

```text
:

id: 2
data: second trade

```

The ids are yours to choose. To resume a PubSub feed, give each message an id when you publish it, keep the recent
ones where every process can read them (a Redis list, a table), and send those after `last_event_id` before you call
`forward`.

## Release resources on shutdown

When the app begins shutting down (`SIGTERM`, `SIGINT` or `App#stop`), every event stream ends at once: `events.open?`
turns `false`, the response ends, and the shutdown does not wait for the streams. The browsers reconnect, to another
instance when a load balancer sends them there. `on_close` runs whenever a stream is over, after a shutdown, a
disconnect or the block's return:

```crystal
Azu::Response::EventStream.new do |events|
  while events.open?
    events.send Time.utc.to_s, event: "clock"
    events.sleep 1.second
  end
end.on_close { Log.info { "clock stream closed" } }
```

`events.sleep` returns early when the stream ends, so the loop stops at once. The [streaming reference](../../reference/api/streaming.md#when-a-stream-ends)
lists every way a stream ends.

## Listen in the browser

```javascript
const source = new EventSource("/prices");

source.addEventListener("price", (event) => {
  const price = JSON.parse(event.data);
  document.querySelector("#price").textContent = price.price;
});

source.onerror = () => {
  // The connection dropped: EventSource reconnects by itself after `retry`.
};
```

The browser sends the page's cookies with the request, so `call` can read the session like any other `GET`. Read what
the stream needs there, before returning the response: the block runs in a fiber of its own, after `call` has
returned. `source.close()` stops the stream for good.

## Test it

`Azu::Testing::Client` returns the response once the block returns, so test a stream that ends: the body is the text
of its events.

```crystal
require "spec"
require "azu"
require "azu/testing"

describe TickerEndpoint do
  it "sends the prices as events" do
    response = Azu::Testing::Client.new.get("/ticker")

    response.content_type.should eq "text/event-stream"
    response.body.should contain %(id: 1\nevent: price\ndata: {"symbol":"AZU","price":12.5}\n\n)
  end
end

describe HistoryEndpoint do
  it "resumes after the last event the client saw" do
    response = Azu::Testing::Client.new.get("/history", headers: {"Last-Event-ID" => "1"})

    response.body.should eq ":\n\nid: 2\ndata: second trade\n\n"
  end
end
```

A stream that never ends, such as `/prices`, never returns there: test what feeds it (the broadcast) on its own, or
serve the app on a port (`app.server(...).bind_unused_port`) and read the stream from a socket.

## See also

- [Streaming and server-sent events](../../reference/api/streaming.md)
- [PubSub](../../reference/api/pubsub.md)
- [Real-time](../../explanation/concepts/real-time.md)

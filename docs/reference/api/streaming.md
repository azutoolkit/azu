# Streaming and Server-Sent Events

Two responses keep the connection open and write the body in pieces: `Azu::Response::Stream` for any
chunked body, and `Azu::Response::EventStream` for [server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html)
(`text/event-stream`). Both are ordinary response types of an `Azu::Endpoint`, flush after every write,
send `Cache-Control: no-cache` and `X-Accel-Buffering: no` (so nginx does not buffer them), answer
`HEAD` with the headers only, and end quietly when the client goes away.

## Event streams

The block runs in its own fiber and sends events to the `Source` it is given:

```crystal
require "azu"

struct ClockEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::EventStream)

  get "/clock"

  def call : Azu::Response::EventStream
    Azu::Response::EventStream.new(heartbeat: 10.seconds) do |events|
      while events.open?
        events.send Azu::Response::EventStream::Event.new(Time.utc.to_s, event: "clock")
        events.sleep 1.second
      end
    end
  end
end
```

An `Event` has `data`, `event`, `id` and `retry`. Data with several lines is written as one `data:` line
per line, as the specification requires; `Event.json(value)` uses the JSON of a value as data. A line
break in `event` or `id` raises `ArgumentError`, since it would end the event early.

`events.send` and `events.sleep` return `false` once the stream is over, so a loop on `events.open?`
stops by itself. `events.forward(channel) { |value| event }` sends one event per value received from a
channel, until the channel closes or the stream ends:

```crystal
require "azu"

struct FeedEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::EventStream)

  get "/feed"

  def call : Azu::Response::EventStream
    Azu::Response::EventStream.new do |events|
      updates = ::Channel(String).new
      spawn do
        updates.send "hello"
        updates.close
      end
      events.forward(updates) { |text| Azu::Response::EventStream::Event.json({text: text}, event: "update") }
    end
  end
end
```

### Reconnecting clients

A browser's `EventSource` reconnects after a drop and sends the id of the last event it saw as
`Last-Event-ID`. `events.last_event_id` holds it (`?lastEventId=` is read too, for clients that cannot set
the header), so the block can resume instead of starting over:

```crystal
require "azu"

struct ResumeEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::EventStream)

  get "/resume"

  def call : Azu::Response::EventStream
    Azu::Response::EventStream.new(retry: 5.seconds) do |events|
      start = events.last_event_id.try(&.to_i?) || 0
      (start + 1..start + 3).each do |n|
        events.send Azu::Response::EventStream::Event.new("event #{n}", id: n.to_s)
      end
    end
  end
end
```

`retry:` tells the client how long to wait before it reconnects.

### When a stream ends

* the block returns;
* a write fails because the client closed the connection. Noticing takes a write, so an idle stream
  notices at the next heartbeat: a `: heartbeat` comment is sent after every `heartbeat` (15 seconds by
  default) without an event, which also keeps proxies from closing an idle connection;
* the app begins shutting down (`Azu.shutting_down?`, `Azu.shutdown_signal`), so a stream never holds the
  drain until `shutdown_timeout`. The client sees the connection close and reconnects, to the next instance.

The `Source` is closed in every case: `open?` is `false`, `send` and `sleep` return `false`, and the
producer fiber ends once the block returns. `on_close { ... }` on the response runs when the stream is over
(for releasing a subscription, say). A block that blocks on something other than the `Source` (a socket
read) is only noticed when it comes back.

An exception in the block is logged, an `event: error` is sent, and the stream ends; the client's
`EventSource` reconnects, as it does after any end of stream, so a producer that fails at once will be
retried at the client's `retry` interval.

### Limits

* A vanished client is noticed by a failing write, so it can take up to two heartbeats (the first write
  after the close may still succeed) before the producer is told to stop and `on_close` runs. Lower
  `heartbeat` to notice sooner.
* A producer blocked on a channel of its own is not interrupted when the stream ends; read it with
  `events.forward(channel)` or `select` on it together with `events.sleep`, or it stays until the channel
  delivers.
* Azu does not cap concurrent streams: each holds a connection and two fibers. Limit them in the endpoint
  (a counter, or `Handler::Throttle`) if clients are not trusted.

## Plain streams

```crystal
require "azu"

struct ExportEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Stream)

  get "/export.csv"

  def call : Azu::Response::Stream
    Azu::Response::Stream.new("text/csv") do |sink|
      sink << "id,name\n"
      1000.times { |id| sink << id << ",row\n" }
    end.on_close { Log.info { "export finished" } }
  end
end
```

The `Sink` is an `IO` that flushes every write. When the client goes away the next write raises, which
ends the block, and `on_close` runs (for `HEAD` too, with no body). An exception from the block after the
headers are sent is logged and ends the body; before that it propagates to the error handler. Unlike an event stream, a `Stream` is not cut short by a shutdown (a
download in flight is allowed to finish within `shutdown_timeout`); a long running block checks
`Azu.shutting_down?` itself.

## Compression

`Azu::Handler::Compression` leaves `text/event-stream` responses alone: compressing them would hold
events back until the compressor's buffer fills. Other streams are compressed and flushed per write.

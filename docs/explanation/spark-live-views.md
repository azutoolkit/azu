# Spark Live Views

Spark keeps server-rendered components in sync with the browser over a WebSocket, in the spirit
of Phoenix LiveView. State lives on the server; the browser sends events; the server renders
again and sends only the HTML of the components that changed.

## Setup

```crystal
class CounterView < Azu::Spark::Component
  mountable

  prop label : String = "Clicks"
  state count : Int32 = 0

  def render
    h2 "#{label}: #{count}"
  end
end

# once, at boot
Azu::Spark.install                       # registers the WebSocket endpoint and the client script
Azu::Spark.configure { |c| c.secret = ENV["SPARK_SECRET"] }

# in a layout
Azu::Spark.script_tag                    # <script src=...> served by your own application

# in a page
Azu::Spark.render(CounterView, label: "Clicks", session: {"user_id" => "42"})
```

The client script is served by the application itself (no CDN, no inline code), so it works
under a strict Content-Security-Policy.

## The component DSL

```crystal
class Counter < Azu::Spark::Component
  mountable

  prop label : String = "Clicks"   # supplied by the page or parent, read only
  state count : Int32 = 0          # owned by the server; changing it re-renders

  def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
    self.count = params.fetch("start", Int32, 0)
    socket.subscribe("counters")   # PubSub topic, cancelled automatically
  end

  event def increment(by : Int32 = 1) : Nil
    self.count += by
  end

  def handle_info(message : Azu::PubSub::Message, socket : Azu::Spark::Socket) : Nil
    self.count = message.payload.to_i
  end

  def render
    div do
      h2 "#{label}: #{count}"
      button "+1", **spark_click(:increment)
    end
  end
end
```

- **`prop` / `state`** declare the component's assigns. `assigns` returns a typed view of both,
  handy in tests.
- **`event def`** is the only way the client can trigger code. Names and parameter types become a
  compile-time dispatch table: a client cannot invoke any other method, and a payload that does
  not fit the declared types is rejected before the handler runs.
- **`mount`, `handle_info`, `unmount`** are the lifecycle callbacks. `mount` runs on the initial
  HTTP render (`socket.connected?` is false) and again when the WebSocket joins.
- **Bindings** (`spark_click`, `spark_change`, `spark_submit`, ...) produce `spark-*` attributes
  with options such as `debounce`, `throttle`, `target`, `confirm` and `disable_with`.
- Inherit directly from `Azu::Spark::Component`; declarations are not inherited from intermediate
  component classes.

## PubSub

`Azu::PubSub` is the process-wide broadcast bus (in-memory by default, `Azu::PubSub::Redis` to
span nodes). Components and `Azu::Channel`s both `subscribe` to topics and receive broadcasts;
subscriptions and timers end with the component or connection.

## JavaScript client

`azu_spark.js` opens one WebSocket per page (`Azu::Spark.config.path`, default `/spark`),
joins every `[data-spark-root]` component with its signed token, forwards DOM events declared by
the bindings, patches the DOM with the HTML the server sends, heartbeats, and reconnects with
backoff and the last signed state snapshot, so the page continues where it was. See
[Spark client and reconnects](../reference/spark-client.md).

### Background tabs and accessibility

A tab that stays hidden for five minutes closes its socket cleanly and rejoins from its last state
snapshot when it is shown again, so idle tabs do not hold server resources and nothing is lost: the
events that were unanswered are sent again in order (`data-spark-hidden-idle` changes the window,
`0` disables it). Connection trouble (reconnecting, offline, an event that was dropped) is announced
through one polite live region that never takes focus, and a component root is marked
`aria-busy` while one of its events is in flight. `Spark.on(...)` and `Spark.stats()` expose the
connection state, round trips, patch timings and delivery counters, redacted when traced. The
[client reference](../reference/spark-client.md#hidden-tabs) has the details and the CSS.

### Compressed frames

A big patch is mostly repeated markup. A browser that can inflate gzip (`DecompressionStream`) says so
when it joins, and from then on the server sends diffs of 1 KB and more as a single gzipped binary
frame, when that is smaller: about a quarter of the bytes for a typical table or list. Everything is
decided per connection, so older clients and browsers without the API keep getting plain text frames,
byte for byte as before. The client applies frames strictly in the order they arrived, caps what a
frame may inflate to (1 MiB) while it streams, and falls back to plain frames if one ever fails to
decode. The threshold is `Azu::Spark.config.compress_threshold` (`0` turns it off). Why this is done in
Spark and not with the WebSocket `permessage-deflate` extension (Crystal's standard library does not
implement it), and how to see it in DevTools, is in
[the client reference](../reference/spark-client.md#compressed-frames).

### Event delivery

A click or an edit is sent as an *event*, and the connection can break at any moment. Spark numbers
every event on the client, keeps it until the server answers, and sends the unanswered ones again after
a reconnect: delivery is **at least once**. The server remembers, per page, the highest number it took,
so a repeat is answered (`dup`) but not applied twice: the state of your components sees each event
once. The answer to an event also carries its number (`ack`), on the diff as well as on the reply, so
an event whose diff arrived is never resent.

What this does not do is undo side effects outside the component: if the connection is cut after your
handler charged a card and before the answer arrived, the resent event runs the handler on the
re-mounted page again. Make such handlers idempotent or mark the control
`delivery: "at-most-once"` (`**spark_click(:pay, delivery: "at-most-once")`): that event is dropped, not
resent, when the connection breaks while it is in flight, and the client reports `event_dropped`.

While you type faster than the server answers, newer values of a control merge into one waiting event
(the latest wins) instead of queueing up, events of a page are never reordered except values of
different controls among themselves, and nothing is sent while an IME composes. If the page had to be
mounted afresh (its snapshot was refused), events made for the old page are refused with `stale_event`
instead of being applied to a view the user never saw. Numbers, limits and every optional protocol
field are in [the client reference](../reference/spark-client.md#events-and-delivery).

## Security model

- **Origin check.** Browser upgrades from a foreign origin are refused with 403. Extra origins go
  in `Azu::Spark.config.allowed_origins` (`SPARK_ALLOWED_ORIGINS`).
- **Signed join token.** `Spark.render` signs the component id, type, props and session claims
  with `config.secret`. A component can only be joined with a valid, unexpired token
  (`token_ttl`). Production and staging refuse to start without an explicit secret.
- **Per-connection ownership.** Each connection has its own component registry
  (`max_components`); events can only address components that connection joined or rendered.
  Reconnect snapshots are signed, expiring, size limited and bound to the page, its session claims
  and the component classes; anything else is refused with `invalid_snapshot`.
- **Limits.** Frame size (`max_message_size`), event rate (`events_per_second` / `event_burst`)
  and idle timeout are enforced per connection. A compressed frame may inflate to 1 MiB at most,
  enforced by the client while it inflates.
- **The client applies server HTML, on purpose.** A live view works by sending rendered HTML
  that the client morphs into the page, so the client parses what the server sends (static
  analysis tools report this as a DOM XSS sink: the value comes from a WebSocket message).
  The layers around it are: the server escapes what it renders; the socket is only opened after
  the origin check and a signed join token; the client parses the patch in an inert document
  (`DOMParser`, so no script runs and no resource loads) and drops `script`, `iframe`, `object`,
  `embed`, `base`, `meta` and `link` elements, every `on*` attribute and `srcdoc`, and script or
  `data:` URLs before moving the nodes into the page; and the client script is served by the
  app with no inline code, so a Content-Security-Policy of `script-src 'self'` works, also with
  `require-trusted-types-for 'script'; trusted-types azu-spark` (see
  [the client reference](../reference/spark-client.md#content-security-policy-and-trusted-types)). Serve the
  socket over `wss` in production: an unencrypted connection could be rewritten in transit.

## Breaking changes

This release replaces the previous Preact/jQuery based Spark.

- `Azu::Spark` is now a module. `ComponentRegistry`, `Spark.javascript_tag`, the `live-*`
  attribute protocol and the `spark_tag()` / `live_click` / `live_change` / `live_input` /
  `live_value` template helpers are removed. Use `Azu::Spark.script_tag` and the binding macros.
- `Azu::Component` is reduced to a static `Markup` component: `mount`, `every`, `on_event` and
  `refresh` are removed. Stateful, interactive components now inherit from
  `Azu::Spark::Component`.
- Channels reject cross-origin browser upgrades by default (403). Behind a proxy that rewrites
  `Host`, set `WEBSOCKET_ALLOWED_ORIGINS` to the public origin(s).
- Messages over 1 MB close the connection (`CloseCode::MessageTooBig`), and the server pings every
  30 seconds (`websocket.ping_interval`).
- `Channel#initialize` now sets up mutexes: subclasses that override it must call `super`.
- New `Channel` methods (`context`, `params`, `headers`, `send`, `close`, `subscribe`,
  `broadcast`) may clash with methods of the same name in subclasses.
- `Router#ws` registers `Channel::Upgrader`, so `Route#endpoint` and `route_info["handler"]`
  change.
- `Azu.start` traps `TERM` as well as `INT` and calls `Azu.shutdown`.
- `Markup`: `disabled: false` is omitted and `disabled: true` renders as a bare attribute.

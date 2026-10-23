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
the bindings, patches the DOM with the HTML the server sends, heartbeats, and reconnects with the
last signed state snapshot.

## Security model

- **Origin check.** Browser upgrades from a foreign origin are refused with 403. Extra origins go
  in `Azu::Spark.config.allowed_origins` (`SPARK_ALLOWED_ORIGINS`).
- **Signed join token.** `Spark.render` signs the component id, type, props and session claims
  with `config.secret`. A component can only be joined with a valid, unexpired token
  (`token_ttl`). Production and staging refuse to start without an explicit secret.
- **Per-connection ownership.** Each connection has its own component registry
  (`max_components`); events can only address components that connection joined or rendered.
  Reconnect snapshots are signed and size limited.
- **Limits.** Frame size (`max_message_size`), event rate (`events_per_second` / `event_burst`)
  and idle timeout are enforced per connection.
- **The client applies server HTML, on purpose.** A live view works by sending rendered HTML
  that the client morphs into the page, so the client parses what the server sends (static
  analysis tools report this as a DOM XSS sink: the value comes from a WebSocket message).
  The layers around it are: the server escapes what it renders; the socket is only opened after
  the origin check and a signed join token; the client parses the patch in an inert document
  (`DOMParser`, so no script runs and no resource loads) and drops `script`, `iframe`, `object`,
  `embed`, `base`, `meta` and `link` elements, every `on*` attribute and `srcdoc`, and script or
  `data:` URLs before moving the nodes into the page; and the client script is served by the
  app with no inline code, so a Content-Security-Policy of `script-src 'self'` works. Serve the
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

# Spark JavaScript client and reconnects

`azu_spark.js` is the browser half of [Spark](../explanation/spark-live-views.md). It has no
dependencies, needs no build step and is served by your application, never by a CDN, so the script
in the browser always speaks the protocol of the server it came from.

## Serving

`Azu::Spark.install` mounts the script at `Azu::Spark.config.assets_path`. The URL carries a content
hash (`?v=...`): with the matching hash the response is cacheable for a year (`immutable`), without
it browsers revalidate through the `ETag`. Use the helpers instead of writing the URL yourself:

```crystal
Azu::Spark.install

Azu::Spark.asset_path  # => "/_spark/azu_spark.js?v=3f9c1d2a4b7e"
Azu::Spark.script_tag  # <script src="..." data-spark-path="/spark" defer></script>
```

The tag has no inline code, so `script-src 'self'` is enough. The script is about 25 KB unminified
and 7.5 KB gzipped (it includes the DOM patcher and the HTML sanitiser, see the security model).

## Connection lifecycle

- **Backoff.** After a lost connection the client reconnects after `500 ms * 2^attempt` (half of it
  plus random jitter, capped at 15 s). The counter resets once the server greets the new socket.
- **Heartbeat.** The server proposes an interval in `hello` (`config.heartbeat_interval`). The client
  sends a heartbeat each interval and drops a connection that has been silent for 2.5 intervals:
  a half open connection (a vanished Wi-Fi, a NAT that forgot the flow) never reports `close`.
- **Browser events.** `offline` drops the socket at once and waits for `online` instead of retrying
  into the void; a tab that becomes visible reconnects immediately or probes the connection with a
  heartbeat that must be answered within 3 s.
- **Server going away.** A close with 1001 or 1012 (`Azu::Spark.shutdown`, a restart or the idle
  timeout) is handled like any lost connection: the client backs off and reconnects to the next
  process.
- **Event queue.** Events raised while there is no connection (up to 50, none older than 60 s) wait
  in a queue and are sent, in order, right after the page has rejoined. An event that carries a
  complete value (a text input's `change`) replaces an older queued event for the same target. Each
  queued event is sent once. An event that was already on the wire when the connection broke has
  an unknown fate and is not repeated: delivery is at most once for those.

## Client API

<!-- skip -->
```javascript
Spark.on("open", ({ attempts }) => {});            // connected and greeted
Spark.on("close", ({ code, reason }) => {});       // 1012 = server restart, 4000 = heartbeat timeout
Spark.on("reconnect", ({ delay, attempts }) => {}); // a reconnect is scheduled in `delay` ms
Spark.on("error", ({ code, message }) => {});      // protocol errors, "queue_full"
Spark.off("open", handler);
Spark.status;     // "connecting" | "connected" | "reconnecting" | "disconnected"
Spark.queued;     // events waiting for a connection
Spark.connect();  // start again after Spark.disconnect()
Spark.disconnect();
```

`Spark` is an alias of `AzuSpark`. The same occasions are dispatched as DOM events on `document`
(`spark:open`, `spark:close`, `spark:reconnect`, `spark:error`, `spark:queued`) and the page status
is mirrored in `<html data-spark-status="...">`, which stylesheets can use.

## Rehydration

Components declare what must survive a reconnect with `persist: true`. Whenever persisted state
changes, the server sends a signed *snapshot* of the page with the next diff; the client keeps the
latest one per root component and sends it with `join` after a reconnect. The server then mounts
the page again (props and session claims come from the signed join token) and hands every component
its state before the first render, so the page continues where it was.

```crystal
class Cart < Azu::Spark::Component
  mountable

  prop currency : String = "USD"
  state items : Array(String) = [] of String, persist: true
  state draft : String = ""

  event def add(item : String) : Nil
    self.items = items + [item]
  end

  def render
    span "#{items.size} items in #{currency}"
  end
end
```

Only `persist: true` state travels, `draft` above starts empty again. The snapshot is signed, not
encrypted: never persist secrets.

A snapshot is accepted only if all of this holds, otherwise the join is answered with an error
with the code `invalid_snapshot`, nothing is mounted and the client joins again without it:

| Check | Refused as |
| --- | --- |
| HMAC-SHA256 signature with `config.secret` | tampered |
| `exp` (`token_ttl`, measured with `Azu::Clock`) | expired |
| size at most `config.max_snapshot_size` (default 4096 bytes) | too large (it is also not issued above the limit) |
| format `v` equals `Snapshot::VERSION` | unsupported version |
| root component id equals the page being joined | another page |
| digest of the page's session claims | another session |
| the class recorded for each component is the class being mounted | unknown component class |

Because the ids are unique per rendered page and the session digest is part of the signature, a
snapshot cannot be replayed on another page, for another user or against another component.
Connection limits are unchanged: the join counts as one frame for the rate limiter, and the
components still count against `max_components`. The components of the dropped connection are
unmounted when its socket closes (their subscriptions and timers end with it).

```crystal
Azu::Spark.configure do |config|
  config.max_snapshot_size = 8192
  config.token_ttl = 12.hours
end
```

## Browser test

`spec/browser/run.sh` drives the example app with Chromium through a TCP proxy that cuts the
connection, refuses new ones, swallows traffic and sends a 1012 close, and asserts backoff,
rehydration, exactly-once delivery of a queued click and heartbeat detection. It needs
`npm i playwright` with a chromium and prints `SKIP` (exit 0) when they are missing; it is not part
of `crystal spec`. `SPARK_SERVER_CMD`, `CHROMIUM_PATH` and `PLAYWRIGHT_MODULE` adapt it to other setups.

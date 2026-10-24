# Spark JavaScript client and reconnects

`azu_spark.js` is the browser half of [Spark](../explanation/spark-live-views.md). It has no
dependencies, needs no build step in your application and is served by it, never by a CDN, so the script
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

The tag has no inline code, so `script-src 'self'` is enough. The served script is minified: about
30 KB, 10,743 bytes gzipped (it includes the patch engine, the HTML sanitiser, the delivery layer,
the observability counters, the live region and the decoder of compressed frames, see the security
model). A spec keeps it under 11,264 bytes (11 KB) gzipped. Options go on the tag as `data-spark-*` attributes (see
[Hidden tabs](#hidden-tabs), [Accessibility](#accessibility)):

## How the client is built

The readable source is `js/azu-spark.js` (an ES2022 module with JSDoc types). The script the shard
embeds and serves, `src/azu/spark/client/azu_spark.js`, is generated from it with esbuild and checked
in, so **application developers never need node**: `shards install` brings the built script.
Only people who change the client need node 22 or newer:

```sh
cd js
npm install        # esbuild, typescript and happy-dom, pinned by package-lock.json
npm run build      # rewrites azu_spark.js (minified IIFE) and azu-spark.d.ts (typings from the JSDoc)
npm run check      # fails when azu_spark.js is stale, without writing
npm test           # node:test unit tests on happy-dom
```

The first line of the built script records the SHA-256 of `js/azu-spark.js`. `crystal spec` (no node
involved) compares that hash with the source and fails with the rebuild instructions when you edited
the source and forgot to rebuild; it also enforces the gzip size budget. The `Spark client` CI job
rebuilds the script and fails on any diff. Commit the source, the script and the typings together.

## Connection lifecycle

The connection is always in exactly one of nine states. `next(state, event)` in `js/azu-spark.js`
is a pure function from a state and an event to the next state and the effects to run; a small
runner executes the effects and owns the timers, and entering a state cancels the timers of the
one it left, so no timer outlives its state.

| State | Meaning | `data-spark-status` | Timers it owns |
| --- | --- | --- | --- |
| `idle` | not connected, nothing scheduled (before start, or the page went into the back/forward cache) | `disconnected` | none |
| `connecting` | socket created, the server has not greeted us | `connecting` (`reconnecting` after a loss) | give up after 10 s |
| `joining` | greeted; waiting for the join of every page root to be answered | `connected` | heartbeat, watchdog, give up after 10 s |
| `open` | joined; events are sent | `connected` | heartbeat, watchdog |
| `closing` | we asked the socket to close (`disconnect()`, `pagehide`) and wait for it | `disconnected` | give up waiting after 3 s |
| `backoff` | the connection was lost; waiting to try again | `disconnected` | the retry delay |
| `offline` | the browser has no network; waiting for `online` | `disconnected` | none |
| `hidden-idle` | closed on purpose (code 1000) after the tab was hidden for the idle window; the tab's return rejoins | `disconnected` | none |
| `stopped` | stopped until `connect()`: `disconnect()`, or a token that can never join | `disconnected` | none |

```text
            connect                 hello                joins answered
   idle ------------> connecting ---------> joining ---------------------> open
                          ^  |                 |  ^                          |  |
          retry elapsed / |  | lost, or        |  | a root is added          |  |
          visible         |  | no hello in 10 s|  +--------------------------+  |
                          |  v                 v                                |
                       backoff <---------- (connection lost: close, dead, ... ) <+
                          |  ^
          offline event   |  | online: retry after a short jittered delay, attempts kept
                          v  |
                        offline

   any state with a socket --stop / pagehide--> closing --closed--> stopped / idle
   open / joining / connecting / backoff / offline --hidden for idleMs--> closing(1000) --closed--> hidden-idle
   hidden-idle --visible / focus / pageshow / an event is made--> connecting (attempts kept)
   stopped / idle --connect / pageshow--> connecting
   closing --pageshow (restored from the bfcache)--> connecting once the close finished
```

- **Backoff.** After a lost connection the client waits a random time between 0 and
  `min(15 s, 500 ms * 2^attempt)` (full jitter, so clients that lost the same server do not return
  together). The attempt counter resets only after a connection stayed open for 10 s: a server
  that accepts a socket and closes it again keeps being backed off from. Nothing else resets it:
  not tab visibility, and not the `online` event, which only shortens the wait to the first
  jittered delay (0 to 500 ms) so that flaky Wi-Fi, a captive portal or a fleet of clients coming
  back together do not retry in a burst.
- **Heartbeat.** The server proposes an interval in `hello` (`config.heartbeat_interval`). The client
  sends a heartbeat each interval (the largest supported interval, 1 to 60 s, that is not above the
  proposal, so it is never slower than the server's idle check expects) and drops a connection that has been silent for 2.5 intervals:
  a half open connection (a vanished Wi-Fi, a NAT that forgot the flow) never reports `close`.
  Silence is measured with `performance.now()`, and a watchdog that itself ran late (a throttled
  or frozen background tab; frames may be waiting unread behind it) does not drop the connection:
  it sends a heartbeat and drops the connection only if no frame arrives within 3 s. The same
  happens when the wall clock jumped further than `performance.now()` (the machine slept), and when
  the network comes back (`online`) or the tab becomes visible with an open connection.
- **Browser events.** `offline` drops the socket at once and waits for `online` instead of retrying
  into the void. A tab that becomes visible while backing off retries at once (keeping the attempt
  counter, so the delays keep growing); with an open connection it probes it with a heartbeat that
  must be answered within 3 s.
- **Server going away.** A close with 1001 or 1012 (`Azu::Spark.shutdown`, a restart or the idle
  timeout) is handled like any lost connection: the client backs off and reconnects to the next
  process.
- **Event queue.** Events raised while there is no connection (up to 50 together with the ones
  nobody acknowledged yet, none older than 60 s) wait in a queue and are sent, in order, once every
  root of the page has rejoined and the server has answered the joins (also after a refused snapshot
  and a fresh join). An event that was already on the wire when the connection broke has an unknown
  fate: it is sent again with its number and the server applies it once (see
  [Events and delivery](#events-and-delivery)).

## Hidden tabs

A browser throttles the timers of a background tab (down to one run a minute), so its heartbeat
cannot be relied on, and a tab nobody looks at still holds a socket, a mounted component tree and
its subscriptions on the server. After the tab has been **hidden for 5 minutes** the client closes
the socket cleanly (code `1000`, reason `hidden idle`) and enters `hidden-idle`. When the tab is
visible again (`visibilitychange`, `pageshow` from the back/forward cache, or the window gaining
focus; focus on a connected tab does nothing, and focus on an idle tab counts as the tab being
shown, so it does not idle again) it reconnects and rejoins every root from the latest stored snapshot, the same path as after
a lost connection, so persisted state survives (see [Rehydration](#rehydration)).

- **The window.** `data-spark-hidden-idle="<milliseconds>"` on the script tag changes it (default
  `300000`); `0` turns the idle close off. `AzuSpark.configure({ hiddenIdle: ms })` does the same at
  runtime for the next time the tab is hidden. The window restarts every time the tab hides; a tab
  that is hidden when the page loads idles from then on.
- **Healthy and hidden is left alone.** Inside the window nothing changes: the heartbeat and the
  watchdog run as before (a late watchdog asks the server instead of dropping the connection), no
  state changes and no event is emitted.
- **No event is lost.** Events that were sent and not answered when the socket closed go back to the
  front of the queue with their numbers, in order, and are resent after the rejoin; the server
  applies each number once. An `at-most-once` event in flight is dropped with the reason
  `disconnect`, as for any lost connection. An event made while the tab sits idle (a timer, a
  `Spark.push`) wakes the connection and is delivered after the join.
- **Backoff stays honest.** An idle close is not a failure and starts no backoff. A tab that idled
  while backing off keeps its attempt counter, so a server that is down still gets longer delays;
  one that idled from a healthy connection starts at attempt 0. The same holds for a tab that
  returns, or makes an event, while the idle close is still finishing.
- **Status while idle.** `data-spark-status` is `disconnected` while the tab idles and `connecting` (`reconnecting` when it
  idled with attempts kept) on its way back, like any other gap, so a banner keyed to `disconnected` flashes for one round
  trip when a tab returns. Tell the two apart with `Spark.stats().state === "hidden-idle"` or the
  `state` event (`to: "hidden-idle"`), or keep such a banner hidden while `document.hidden`.
- **Server.** A client close with `1000` is an ordinary disconnect: the connection ends without a
  warning or error log, its components are unmounted and their subscriptions released, exactly as
  for any other close. The idle close needs no server change.

## Events and delivery

### Event attributes

The binding macros (`spark_click`, `spark_change`, ...) render these attributes; you can also write
them by hand. An element reacts when it, or an ancestor inside a component, has `spark-<kind>="event"`:

| Attribute | Meaning |
| --- | --- |
| `spark-click`, `spark-submit`, `spark-change`, `spark-keydown`, `spark-keyup`, `spark-blur`, `spark-focus` | send the named `event def` of the component |
| `spark-value-<name>="v"` | extra payload entry `name` (dashes become underscores) |
| `spark-key="Enter"` | key events (`keydown`, `keyup`) only react to that key; on `keydown` the browser default is cancelled for it |
| `spark-debounce="ms"` / `spark-throttle="ms"` | rate limit the event in the browser |
| `spark-target="parent"`, `"root"` or a CSS selector | send to another component |
| `spark-confirm="text"` | ask first |
| `spark-disable-with="text"`, `spark-optimistic-class="cls"` | loading state until the event is answered |
| `spark-delivery="at-most-once"` | do not resend this event after a reconnect (default: at least once) |

`spark-change` fires on every edit of a text control (`input`) and on `change` of all others
(checkbox, radio, select, range ...).

### One listener per event type

The client registers one listener per DOM event type on `document`, not one per element, so patches
that add and remove thousands of elements cost nothing, and elements that arrive later work at once.
Listeners that never cancel an event (`input`, `change`, `keyup`, `blur`, `focus`) are passive; `click`,
`submit` and `keydown` are not, because the browser default is cancelled for a `spark-click`,
`spark-submit` or a matching `spark-key`.

### IME composition and trailing events

- While an IME composes (`isComposing`, or the `229` key code some browsers use for the key that confirms
  a composition) no `input`, `keydown` or `keyup` event is sent: the text is not final and the key is
  not a key press. `compositionend` sends the final text of a `spark-change` control instead.
- A debounced event is sent at once, in its place in line, when its control loses focus, when the
  form it is in is submitted (so the server sees the last value before the submit), and when the page
  is hidden or closed (`pagehide`, `visibilitychange`). The last keystroke is not lost to a pause that
  never ends.

### Coalescing and order

An event that carries a whole value (`spark-change` of a text control) is *coalescing*. While an
earlier event of the same control is in flight (sent, not answered), newer values of that control do not
pile up: they merge into one waiting event, and the latest value wins. The control is identified by
component, event name, DOM event kind and the control's `name` (or `id`). Checkboxes, radios and selects are never
merged: every change is its own event.

Events reach the server in the order they were made, with one allowed exception: the value events of
*different* controls waiting in the queue may swap places (each control still sends only its latest
value). An event that has to wait for a value in flight also holds back everything made after it for
the same root, which is how a click made after typing cannot overtake the text. Other roots are
independent. Events of one root are processed by the server one at a time, in arrival order.

### Numbers, acknowledgements and resending

Each event gets a number (`eid`) when it is first sent. Numbers increase for the life of the page and
survive reconnects. The client keeps every sent event until the server answers it (a `reply` or
`error` for its request id, or an `ack` of its number, whichever arrives first). When the connection
breaks, unanswered events go to the front of the queue and are sent again in order, with the same
numbers, after the page has rejoined: **delivery is at least once**, and an event marked
`spark-delivery="at-most-once"` is dropped instead.

The server keeps one number per root of the **connection**, the highest it took, and answers an event at or
below it with a `reply` that has `"dup": true` and does nothing. So a repeat or an older number that arrives
on the same connection is ignored, and nothing grows with the number of events. A resend after a reconnect
arrives on a *new* connection with no such number, by design (see "What once covers" below): its protection
comes from the snapshot the page is mounted from and from `gen`. An event without `eid` (an older client) is
always applied: protocol v1 is unchanged.

| Frame | Field | Meaning |
| --- | --- | --- |
| client `event` | `eid` | the event's number (optional) |
| client `event` | `gen` | the generation of the root, from the reply to its join (optional) |
| server `diff`, `reply`, `error` | `ack` | the `eid` of the event this frame answers |
| server `reply` | `dup` | `true`: that number was applied before, nothing was done |
| server `reply` to a `join` | `gen` | the generation of the root's state (only when something is persisted) |

All fields are optional in both directions and ignored by a peer that does not know them. `ack` is on the
`diff` too, so an event whose diff arrived is cleared even when its reply is lost with the connection.

An acknowledgement is recorded the moment the frame arrives, before its patches are applied, so a connection
that closes right after cannot make the client send an event again whose effect the snapshot it rejoins
with already holds.

What "once" covers: the *state of the components*. After a reconnect the server mounts the page from the last
snapshot the client holds, and applies the resent event to it, so a component that persists its state ends
up with the event applied exactly once whether or not the first attempt reached the old connection.
Side effects *outside* the component (a payment, an email, an insert) are different: the old connection
may have run the handler before it was cut, and the new one runs it again. Make such handlers idempotent,
or mark them `spark-delivery="at-most-once"`.

```crystal
class Checkout < Azu::Spark::Component
  mountable

  state paid : Bool = false, persist: true

  event def pay : Nil
    return if paid # the page state says so; also check your own records for a payment already made
    self.paid = true
  end

  def render
    button "Pay", **spark_click(:pay, delivery: "at-most-once", disable_with: "Paying...")
  end
end
```

### When the page was mounted afresh

A reply to a `join` names the *generation* of a root that persists state; a snapshot keeps it, so a
reconnect that restores the page keeps the generation. If the snapshot is refused (expired, tampered, the
app changed) the page is mounted afresh with a new generation. An event made for the old one (its `gen`
differs) is not applied: the server answers `stale_event`, the client drops it and says so with
`event_dropped` (reason `stale`). Roots that persist nothing have no generation and are never stale.

A server restart is a new connection with no delivery state: numbers start again from nothing, resent
events are applied (a repeat of one the old process had applied is possible, as above), and the page is
restored from the snapshot if the secret is the same (otherwise: `invalid_snapshot`, a fresh generation,
`stale_event` for the old events).

A queued event keeps the `gen` it was made with (a value merged into a waiting event keeps the older
one's). If the root is rejoined before the event is sent and got a new generation, the event is refused
with `stale_event` and dropped; that is the intended outcome, not a bug.

### Limits

- At most 50 events wait or are unacknowledged (`queueMax`); beyond that the oldest is dropped, reported as
  `spark:event_dropped` (reason `queue_full`) and as the `queue_full` error.
- `event_dropped` means the client forgot the event, **not** that the server did not apply it: a dropped
  `queue_full` or `disconnect` event may have been applied (and its effect may arrive in a later diff).
  The oldest event is dropped first, sent or waiting.
- An event older than 60 s when it could be sent is dropped (`expired`).
- A numbered event refused by the rate limiter is answered with `rate_limited` carrying its `id` and `ack`;
  the client forgets it (`event_dropped`, reason `rate_limited`). The limiter still counts it. It is not resent: a
  coalesced value event that is refused (say the last keystroke of a burst) is lost until the control changes again.
- A compressed frame inflates to at most 1 MiB, see [Compressed frames](#compressed-frames).
- A frame above `max_message_size` is refused by the client (`too_large`) and, if it gets to the server,
  closes the connection as before. The rate limit (`events_per_second`, `event_burst`) counts a resent
  event like any other. Event numbers add about 10 bytes to a frame.
- `event_dropped` reasons: `queue_full`, `expired`, `disconnect` (an at-most-once event in flight),
  `stale`, `rate_limited`, `stopped` (`Spark.disconnect()`).

## Compressed frames

A diff that replaces a big component is mostly repeated markup, and it compresses about four to one.
Spark can send such a diff compressed, **if the browser says it can read it**. Nothing changes for
any other client.

```crystal
Azu::Spark.configure do |c|
  c.compress_threshold = 2048 # bytes of JSON; default 1024 (SPARK_COMPRESS_THRESHOLD), 0 turns it off
end
```

### Negotiation

1. The client puts `"enc": ["gzip"]` in its `join` when `DecompressionStream` exists. A browser
   without it announces nothing, and so does a client that is older than this feature.
2. The server notes it for the connection and answers the join with `"enc": "gzip"` (a client that
   announced nothing gets the reply it always got).
3. From then on a `diff` frame of at least `compress_threshold` bytes is sent as **one binary
   WebSocket frame holding the gzip of the exact JSON** the text frame would have carried, but only
   when that is smaller. Everything else (`reply`, `error`, `heartbeat`, `redirect`, small diffs) stays text.

`enc` is a choice of the *connection*, not of a root: the latest `join` decides. A later join that
announces nothing turns compression off for the whole connection, and one that announces `gzip` turns it on.

A client that announced no encoding is sent text frames only, byte for byte as before; an old client
never receives a binary frame. The protocol version stays 1: `enc` is an optional field both sides ignore
when they do not know it.

### Why not `permessage-deflate`

The WebSocket extension would be negotiated by the browser and the server with no change to the
protocol, but Crystal's `HTTP::WebSocket` (1.19.1 and 1.22.0 alike) cannot do it: the upgrade handler
never reads `Sec-WebSocket-Extensions` or answers it, and the frame reader looks only at the opcode,
so it would neither inflate an incoming frame nor set RSV1 on an outgoing one. Without the extension
the browser never offers compressed frames, so the application-level scheme above is the only choice
that works with the standard library.

### Order, limits and failures

- **Order.** Inflating is asynchronous, so the client keeps one line: while a binary frame is being
  inflated every frame behind it waits, and frames are applied strictly in the order they arrived.
  A text `reply` that follows a binary diff is handled after the diff's patches, so the
  acknowledgement rules of [Numbers, acknowledgements and resending](#numbers-acknowledgements-and-resending)
  hold unchanged. A text frame with nothing ahead of it is handled at once, as before.
- **Compressed size.** A binary frame larger than 524,288 bytes (`Protocol::MAX_COMPRESSED`) on the wire is
  rejected before anything is inflated (Chrome's `DecompressionStream` may emit many chunks before a cancel
  lands), and the server sends such a frame as text.
- **Size.** A frame may inflate to at most 1,048,576 bytes (`Azu::Spark::Protocol::MAX_INFLATED`). The
  server never compresses a larger frame (it is sent as text), and the client counts the bytes while it
  streams the inflation and stops at the limit, so a bomb is never held in memory whole. This is not
  `max_message_size`, which limits what a *client* may send (64 KB by default).
- **Failure.** A frame that cannot be inflated (corrupt, truncated or over the limit) is reported as the
  `patch_failed` error; the client resets the connection and rejoins from its last snapshot (so the lost diff
  is not skipped), and **asks for plain frames for the rest of the page's life**, so a frame that fails
  once cannot make the page loop. A frame that has not inflated after 5 seconds (not configurable;
  `config.inflateTimeout` in the source) is treated the same way: otherwise it would hold every later
  frame, heartbeats included, behind it.
- **Proxies that dislike binary frames.** If a connection ends (other than a normal or going-away close)
  after the first binary frame it received and before any text frame was applied since, the client
  concludes that something on the path rejects binary frames and asks for plain frames for the rest of
  the page. The server side escape hatch is `SPARK_COMPRESS_THRESHOLD=0` (or
  `config.compress_threshold = 0`): no binary frame is ever sent.
- **Cost.** The server compresses at gzip level 1 in the connection's own processing fiber, never in the
  read loop, and not at all while more work waits behind the current job (a busy connection sends text).
  Cost is bounded by the size cap, and below the threshold it is zero.
- **Accounting.** `Spark.stats().bytes.in` counts the bytes that crossed the wire, so a compressed frame
  counts its compressed size.

### Checking it in the browser

Open DevTools, Network, filter WS and pick the `/spark` socket. Messages: a text frame shows its JSON,
a compressed one is listed as "Binary Message" with its (small) length. The join frame shows
`"enc":["gzip"]`, and the reply to it `"enc":"gzip"`. To see the old behaviour in the same browser,
run `delete window.DecompressionStream` in a script that runs before the page's (or the Playwright
`addInitScript` of `spec/browser/spark_compress.cjs`) and reload: the join announces nothing and every
frame is text. Measured on the demo app's report component (150 rows, one "Next page" click): 12.1 KB as
text, 3.0 KB compressed. To reproduce, run `spec/browser/run.sh` (or `node spec/browser/spark_compress.cjs`
with the same environment): it prints the bytes of the six diffs of each tab and the totals on the wire
(DevTools protocol frame sizes: payload bytes, no WebSocket headers).

## Client API

<!-- skip -->
```javascript
Spark.on("state", ({ from, to, reason, attempts }) => {}); // see Observability
Spark.on("open", ({ attempts }) => {});            // connected and greeted
Spark.on("close", ({ code, reason }) => {});       // 1012 = server restart, 4000 = heartbeat timeout
Spark.on("reconnect", ({ delay, attempts }) => {}); // a reconnect is scheduled in `delay` ms
Spark.on("error", ({ code, message }) => {});      // protocol errors, "queue_full", "stale_event"
Spark.on("event_dropped", ({ event, reason }) => {}); // an event will never be delivered
Spark.off("open", handler);
Spark.status;     // "connecting" | "connected" | "reconnecting" | "disconnected"
Spark.queued;     // events waiting to be sent
Spark.unacked;    // events sent and not yet answered
Spark.connect();  // start again after Spark.disconnect()
Spark.disconnect();
Spark.stats();    // a snapshot of counters, see Observability
Spark.configure({ hiddenIdle: 60000, live: true, debug: false, text: { stale: "Veraltet" } });
```

`Spark` is an alias of `AzuSpark`. The same occasions are dispatched as DOM events on `document`
(`spark:open`, `spark:close`, `spark:reconnect`, `spark:error`, `spark:queued`, `spark:event_dropped`) and the page status
is mirrored in `<html data-spark-status="...">`, which stylesheets can use.

## Observability

`Spark.on(name, fn)` subscribes to the events below (and to the ones above); `Spark.off` removes the
handler. The same occasions are dispatched as `spark:<name>` DOM events (a `CustomEvent`, `detail`
holds the object shown) on `document`. The first four are **telemetry**: they cost a few integer
increments while nobody listens, because the detail object and the DOM event are only made for a
name somebody subscribed to with `Spark.on` (a plain `addEventListener("spark:rtt", ...)` hears
nothing unless some `Spark.on("rtt", ...)` or debug tracing is active).

| Event | `detail` | When |
| --- | --- | --- |
| `state` | `{ from, to, reason, attempts }` | every change of the connection state (`idle`, `connecting`, `joining`, `open`, `closing`, `backoff`, `offline`, `hidden-idle`, `stopped`); `reason` names the machine event that caused it (`hello`, `closed`, `dead`, `hide_idle`, `visible`, ...) |
| `reconnect` | `{ delay, attempts }` | a reconnect is scheduled in `delay` ms; `attempts` counts the failed attempts so far (always emitted, with `backoff`) |
| `rtt` | `{ ms, p50 }` | a heartbeat was answered: its round trip and the median of the last 16 |
| `timing` | `{ patches, ms }` | one animation frame applied `patches` patches in `ms` milliseconds |
| `delivery` | `{ phase, event, eid }` | an event was `sent` for the first time, `resent` after a reconnect, `acked` (answered), or `dropped` |
| `event_dropped` | `{ event, reason }` | an event will never be delivered (always emitted) |

`Spark.stats()` returns a fresh snapshot object (cheap, no listener needed). TypeScript users get
the types of `window.AzuSpark` from `js/azu-spark-global.d.ts` (`import "azu-spark-global"`, or
add it to `files`), next to the generated `azu-spark.d.ts` (`SparkStats`, `SparkOptions`,
`SparkTelemetry`):

<!-- skip -->
```javascript
Spark.stats();
// {
//   state: "open", attempts: 0,
//   rtt: { last: 12.4, p50: 11.8 },           // null until a heartbeat was answered
//   queue: { waiting: 0, unacked: 1 },        // waiting to be sent / sent and not answered
//   bytes: { in: 18342, out: 2210 },          // UTF-16 units of the text frames: bytes for ASCII, fewer for other text
//   patches: { applied: 41 },
//   delivery: { sent: 12, resent: 1, acked: 12, dropped: 0 },
//   reconnects: 1                             // reconnects scheduled since the page loaded
// }
```

**Debug tracing.** `localStorage.setItem("azu-spark:debug", "1")` (then reload) or
`Spark.configure({ debug: true })` prints every event as `console.debug("[azu-spark]", name, detail)`
and also turns the telemetry events on. The detail is **redacted**: numbers and booleans are shown,
strings only for the keys `from`, `to`, `reason`, `code`, `event` and `phase` (states, reasons,
error codes, event names); every other value (error messages, payloads, tokens, snapshots, HTML)
shows as `"<string>"` or `"<object>"`. Events that the server pushes to a component carry the
application's data and are never traced. Nothing is traced by default.

## Accessibility

**Live region.** Connection trouble is announced to assistive technology through one polite live
region. It is created on the first announcement (`role="status"`, `aria-live="polite"`,
class `azu-spark-live`) and appended to `<body>`; if the page already has an
element with `data-spark-live-region` **outside any component**, that element is used instead and
nothing is created (one inside a `data-spark-id` component is ignored, because a patch could
overwrite it), so there is never more than one. It never takes focus and does not move the caret.
Each announcement blanks the region and sets the text 100 ms later, so the same words are read
again when they repeat. Connection announcements (`reconnecting`, `offline`, `restored`) and
`stale` have separate timers: a dropped event never cancels the announcement of a lost
connection or the all clear. Messages that fall together are spoken one after the other (each
one for 200 ms, blank then text), none replaced. Disconnecting the client cancels what waits to be
said. Messages:

| Key | Said when | Default text |
| --- | --- | --- |
| `reconnecting` | the connection was lost and is still down after 1 s (a quick reconnect says nothing) | `Reconnecting...` |
| `offline` | the browser went offline | `Offline. Live updates are paused.` |
| `stale` | an event was dropped (`stale_event`, `rate_limited`, a full or expired queue, a connection that broke an `at-most-once` event) | `This page may be out of date.` |
| `restored` | the connection is back after `reconnecting` or `offline` was said | `Back online.` |

An idle close of a hidden tab says nothing, and neither does the return from it (a pending
`reconnecting` or `offline` announcement is dropped when the tab goes idle). An empty text for
`restored` still clears the region.

**Words.** Defaults are English. Replace one with an attribute on the script tag, or a dictionary
(the dictionary wins); an empty string silences that message, and `data-spark-live="off"` (or
`Spark.configure({ live: false })`) turns the region off:

```html
<script src="/_spark/azu_spark.js?v=3f9c1d2a4b7e" data-spark-path="/spark" defer
        data-spark-text-reconnecting="Verbindung verloren, neuer Versuch..."
        data-spark-text-offline="Offline"
        data-spark-text-restored=""></script>
```

<!-- skip -->
```javascript
Spark.configure({ text: { stale: "Diese Seite ist vielleicht veraltet." } });
```

**Visually hidden without an inline style.** The client hides its region by setting CSSOM
properties (`element.style.position = "absolute"`, ...), which a `style-src` without
`'unsafe-inline'` allows (a `style=""` attribute in markup would not be); it is verified in
Chromium under `default-src 'none'`. If you would rather own the look, or supply your own region,
this is all it needs:

```css
.azu-spark-live, [data-spark-live-region] {
  position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0);
}
```

**`aria-busy`.** While an event of a component root is in flight (from the user's action to the
answer and the paint of its patches), the root gets `aria-busy="true"`, and loses it when the last
such event is done. The attribute appears only if the event is still unanswered after 150 ms, so a
quick round trip never makes it flicker (a root that already uses `aria-busy` yourself is
overwritten). It is cleared too when the event is dropped, expires (10 s without an answer) or
the client stops.

**Motion.** The client has no animation or transition of its own: it never scrolls, animates or
sets a transition, so there is nothing to switch off for `prefers-reduced-motion`. Loading states
you add with `spark-optimistic-class` are your CSS; guard their transitions with
`@media (prefers-reduced-motion: reduce)`.

## Patch semantics

The server sends the new inner HTML of a component and the client edits the live DOM into it; it
never assigns `innerHTML` to a live node. Patches that arrive within one frame are applied together
in a single `requestAnimationFrame`. A 50 ms timer is the fallback; background tabs throttle
timers to about once a second, so queued patches are also applied when the tab becomes visible: everything that has to be
read (focus, caret, scroll offsets) is read first, then all patches are written, then the state is
restored. A `patch` event (`Spark.on("patch", ({ id }) => ...)`, `spark:patch` on the component)
fires after each one.

**Matching.** Children of a node are matched to the new children by key, then by position:

| Key (first present wins) | Used for |
| --- | --- |
| `data-spark-id` | child components (never morphed by the parent: they patch themselves) |
| `data-spark-key` | the items of a list; any element |
| `id` | any element |

A keyed node keeps its identity when it moves, so its focus, scroll offset, media playback and
form state go with it. Preserving media and iframe state across a move needs a browser with
`moveBefore` (Chrome 133 and newer); elsewhere a moved element is re-inserted and may restart.
Nodes without a key match the next unkeyed node of the same type; a node the server inserted does
not steal the match of a later one. Only the nodes outside the longest run that is already in
order are moved (rotating a 1000 item list moves
one node), a key that disappeared is removed, a new key is inserted, and where the browser has
`moveBefore` it is used, so a moved node is not even detached. Keys match among siblings and must be
unique there. Give list items a stable key:

```crystal
class Todos < Azu::Spark::Component
  mountable

  state items : Array(String) = [] of String

  def render
    ul do
      items.each_with_index do |item, index|
        li item, "data-spark-key": "item-#{index}"
      end
    end
  end
end
```

A child component that did not change is sent as an empty slot and keeps its live element, also
when the parent now wraps it in a new element.

**What a patch does not disturb.**

| State | Rule |
| --- | --- |
| Focus, caret, selection | Kept. A control that had to be moved is focused again with its selection (contenteditable too). |
| Scroll offsets | Of every element in the patched components, restored if a move reset them. |
| Text inputs, textareas | The user's text wins while the control is focused or an IME is composing in it (no value is written, and the server's new value stays pending for the next patch). Otherwise the property follows the attribute only when the server *changed* the attribute: a half typed, unfocused value survives re-renders that do not mention it. To clear a field from the server, render a different `value`, or give the element another `data-spark-key`. |
| `checked`, `selected` | Same rule: applied when the server's attribute changed. |
| `<details>`, `<dialog>` | What the user opened or closed stays until the server's `open` changes. |
| Media (`audio`, `video`) | The element is edited in place, so playback continues; only attributes that changed are written. |
| Contenteditable | The content of a focused editable region is not patched. |
| `spark-ignore` | A subtree with this attribute is never touched. |

Boolean attributes (`disabled`, `hidden`, ...) are added and removed, and `data-*` attributes are
synced like any other.

**Scripts.** `script` elements in a patch are removed. A component inside an element with
`data-spark-allow-scripts` (which also covers the components nested in it) keeps them. Only the
server-rendered page can set that attribute: a patch can neither add it nor remove it, it is stripped
from patch HTML. The client then creates a fresh copy of each new script so
it runs once (an unchanged script is not run again). That needs `'unsafe-inline'` or a nonce in the
CSP and is refused under Trusted Types, so it is off by default and not recommended. Event handler
attributes, `javascript:` URLs, `iframe`, `object` and the other blocked elements are removed always,
and so is an `action` or `formaction` that points to another origin. The server-rendered first
page is not filtered, so a component that posts to another origin works until its first patch and
then loses the attribute: post to your own origin and redirect instead. `<style>` elements are **not**
stripped: a style can reach the page through `@import` and attribute selectors, so keep untrusted
text out of styles and set `style-src` (and `connect-src`/`img-src`) in your CSP.

## Content-Security-Policy and Trusted Types

The client works under a strict policy with no inline script and no `eval`:

```text
Content-Security-Policy: script-src 'self'; require-trusted-types-for 'script'; trusted-types azu-spark
```

Parsing a patch is a Trusted Types sink. When `window.trustedTypes` exists, the client creates one
policy named **`azu-spark`** and uses it for exactly one thing: turning the patch string into
`TrustedHTML` for `DOMParser`, which builds an inert document. The nodes are sanitised (see the
security model) before any of them reaches the page. The policy is not exposed, has only
`createHTML` (no `createScript` or `createScriptURL`), and the client never registers a `default`
policy. Your `trusted-types` list has to name `azu-spark`; without it the client falls back to
plain strings, which the browser rejects when `require-trusted-types-for 'script'` is on. The patch
is then not applied and a `spark:error` with the code `patch_failed` reports it. With `SecurityHeaders`:

```crystal
Azu::Handler::SecurityHeaders.new(
  content_security_policy: "script-src 'self'; require-trusted-types-for 'script'; trusted-types azu-spark"
)
```

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

Only `persist: true` state travels, `draft` above starts empty again.

**Persisted state is not authority.** The snapshot is signed, not encrypted, so the browser can
read it, and it can replay an old one until it expires (`config.snapshot_ttl`, default one hour,
`SPARK_SNAPSHOT_TTL`; the join token lives for `token_ttl`). On rejoin the restored state
overwrites what `mount` computed. Never persist secrets or anything that grants rights
(`is_admin`, `user_id`, prices, permissions): keep those in the session claims of the join token
or look them up again in `mount` and `event` handlers. A snapshot that expired before a reconnect
is refused and the page starts afresh.

A snapshot token is sent with a diff only when the persisted state changed (it is not debounced:
persist small, rarely changing state). Joining a root that is already mounted is refused with
`bad_request` and leaves the live root alone; a failed join unmounts every component it mounted.

A snapshot is accepted only if all of this holds, otherwise the join is answered with an error
with the code `invalid_snapshot`, nothing is mounted and the client joins again without it:

| Check | Refused as |
| --- | --- |
| HMAC-SHA256 signature with `config.secret` | tampered |
| `exp` (`token_ttl`, measured with `Azu::Clock`) | expired |
| state is a JSON object | malformed |
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
  config.snapshot_ttl = 30.minutes
end
```

## Browser test

`spec/browser/run.sh` drives the example app with Chromium through a TCP proxy that cuts the
connection, refuses new ones, swallows traffic and sends a 1012 close, and asserts backoff,
rehydration, exactly-once delivery of a queued click, heartbeat detection and the probe of a tab
that becomes visible. It starts the app on free ports with `SPARK_HEARTBEAT_INTERVAL=1` and fails at
once, naming the cause, when the server does not propose a 1 s heartbeat: a command that runs the
app in a container has to forward that variable. It needs
`npm i playwright` with a chromium and prints `SKIP` (exit 0) when they are missing; it is not part
of `crystal spec`. `SPARK_SERVER_CMD`, `CHROMIUM_PATH` and `PLAYWRIGHT_MODULE` adapt it to other setups.

`spec/browser/spark_compress.cjs` (also run by `run.sh`) opens the example app twice, once as a modern
browser and once with `DecompressionStream` removed, and makes the same clicks on its 150-row report.
The two tabs must show the same page; the modern one receives binary frames that interleave with text
replies, the old one text only, and the bytes on the wire are printed. A gzip bomb delivered to the modern tab must
fail as `patch_failed`, after which the tab rejoins without announcing gzip and keeps working.

`spec/browser/spark_patch.cjs` (run by the same `run.sh`) checks the patch engine in Chromium: with
two tabs on the example app, a patch lands while the other tab has a half typed value, a caret
selection, an open IME composition (driven through the DevTools `Input.imeSetComposition`) and a
scrolled list, and none of them may change. Scripted pages then check keyed moves with and without
`moveBefore`, scripts with and without the opt-in, and patches under a Content-Security-Policy that
enforces Trusted Types, with and without `azu-spark` in the `trusted-types` list.

`spec/browser/spark_idle.cjs` (also run by `run.sh`) gives the example app's script tag a 1.5 s
`data-spark-hidden-idle` and fakes a hidden tab by overriding `document.visibilityState` (headless
Chromium has no hidden tabs): a short absence leaves the socket alone, a long one closes it with
code 1000 and `hidden idle` (checked on what the client asked for: the browser reports the server's
echo, which carries no status, as 1005), no socket is opened while it idles, and the return rejoins
with the counter intact. An event made while idle wakes the connection and takes effect once. A
scripted page under `default-src 'none'` checks `aria-busy` (absent for a 50 ms answer, present
after 150 ms), that exactly one live region exists, is 1x1 px and absolute without a CSP violation,
announces the lost and the restored connection, and that focus stays where it was.

`spec/browser/spark_delivery.cjs` (also run by `run.sh`) checks event delivery on the example app through the
same kind of proxy: 22 keystrokes typed faster than the server answers (it takes 120 ms per edit) become
a handful of events whose last value wins, with increasing numbers and the field keeping what was typed;
and a slow event (`+1 (slow)`) whose connection is cut while the server works is sent again after the
reconnect with the same number on another connection, and the counter ends up one higher, exactly once.

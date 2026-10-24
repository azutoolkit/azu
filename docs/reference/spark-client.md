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
21 KB, under 8 KB gzipped (it includes the patch engine and the HTML sanitiser, see the security
model). A spec keeps it under 8 KB gzipped.

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
| `hidden-idle` | closed on purpose while the tab is hidden (reserved: nothing enters it yet) | `disconnected` | none |
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
   stopped / idle / hidden-idle --connect / pageshow--> connecting
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
- **Event queue.** Events raised while there is no connection (up to 50, none older than 60 s) wait
  in a queue and are sent, in order, once every root of the page has rejoined and the server has
  answered the joins (also after a refused snapshot and a fresh join). An event that carries a
  complete value (a `change` of a control) replaces an older queued event of the same control (same
  component, event and control name or id); other controls are never merged. Each
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

## Patch semantics

The server sends the new inner HTML of a component and the client edits the live DOM into it; it
never assigns `innerHTML` to a live node. Patches that arrive within one frame are applied together
in a single `requestAnimationFrame` (a 50 ms timer is the fallback; background tabs throttle timers to about once a second, so queued patches are also applied when the tab becomes visible): everything that has to be
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
form state go with it (preserving media and iframe state across a move needs a browser with `moveBefore`, Chrome 133 and newer; elsewhere a moved element is re-inserted and may restart). Nodes without a key match the next unkeyed node of the same type. Only
the nodes outside the longest run that is already in order are moved (rotating a 1000 item list moves
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
and so is an `action` or `formaction` that points to another origin. `<style>` elements are **not**
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

`spec/browser/spark_patch.cjs` (run by the same `run.sh`) checks the patch engine in Chromium: with
two tabs on the example app, a patch lands while the other tab has a half typed value, a caret
selection, an open IME composition (driven through the DevTools `Input.imeSetComposition`) and a
scrolled list, and none of them may change. Scripted pages then check keyed moves with and without
`moveBefore`, scripts with and without the opt-in, and patches under a Content-Security-Policy that
enforces Trusted Types, with and without `azu-spark` in the `trusted-types` list.

/*! Azu Spark client. No dependencies; served by the application itself (see Azu::Spark::Client). */
/**
 * Source of truth of the Spark browser client (ES2022 module, JSDoc types). It is not served as is:
 * `node build.mjs` bundles it into the minified script under src/azu/spark/client/azu_spark.js,
 * which the shard embeds. Edit this file, rebuild, commit both. See docs/reference/spark-client.md.
 *
 * Importing the module boots the client (it is a script, not a library); the exports exist for the
 * unit tests in test/ and are dropped from the shipped script.
 */

/**
 * @typedef {"connecting" | "connected" | "reconnecting" | "disconnected"} SparkStatus
 * @typedef {{ message: Record<string, unknown>, undo?: (() => void) | null, key?: string | null, at: number, root: string, once: boolean, sentAt?: number }} QueuedEvent
 * @typedef {{ v: number, type: string, id?: number, [field: string]: unknown }} SparkMessage
 * @typedef {{ state: string, attempts: number, rtt: { last: number | null, p50: number | null }, queue: { waiting: number, unacked: number }, bytes: { in: number, out: number }, patches: { applied: number }, delivery: { sent: number, resent: number, acked: number, dropped: number }, reconnects: number }} SparkStats what AzuSpark.stats() returns
 * @typedef {{ state: { from: string, to: string, reason: string, attempts: number }, rtt: { ms: number, p50: number | null }, timing: { patches: number, ms: number }, delivery: { phase: "sent" | "resent" | "acked" | "dropped", event: string, eid: number }, reconnect: { delay: number, attempts: number } }} SparkTelemetry the detail of each AzuSpark.on(name) event named here
 * @typedef {{ hiddenIdle?: number, live?: boolean, debug?: boolean, text?: Partial<Record<"reconnecting" | "offline" | "stale" | "restored", string>> }} SparkOptions what AzuSpark.configure() takes
 */

var PROTOCOL = 1;
var script = document.currentScript;
export var config = {
  path: (script && script.getAttribute("data-spark-path")) || "/spark",
  backoffMin: 500,
  backoffMax: 15000,
  requestTimeout: 10000,
  probeTimeout: 3000,
  stableAfter: 10000, // a connection must stay open this long before the backoff starts over
  queueMax: 50,
  queueMaxAge: 60000,
  idleMs: attr("hidden-idle") === null ? 300000 : Math.max(0, parseInt(attr("hidden-idle"), 10) || 0), // a tab hidden this long closes its socket (0: never)
  live: attr("live") !== "off", // the live region for assistive technology
  busyDelay: 150 // aria-busy appears only for an event unanswered this long
};
var debug = false; // console tracing: localStorage["azu-spark:debug"] = "1", or AzuSpark.debug = true
try { debug = localStorage.getItem("azu-spark:debug") === "1"; } catch (e) { /* storage blocked */ }
var text = {}; // AzuSpark.configure({text}): the words of the live region, by key

function attr(name) {
  return script ? script.getAttribute("data-spark-" + name) : null;
}

var ws = null;
var status = "disconnected";
var hello = null;
var nextId = 0;
var lastEid = 0; // the number of the last event sent for the first time: events are numbered per page, not per connection
var booted = false;
var gens = new Map(); // root id -> the generation of its state, as the server named it in the reply to the join
var pending = new Map(); // request id -> the event sent on it and not yet acknowledged
var queue = []; // events waiting to be sent: first those to resend (they keep their number), then the new ones
var joining = new Map(); // join request id -> root id
var handlers = {}; // Spark.on(...)
var joined = new Set(); // root ids joined on the current socket
var snapshots = new Map(); // root id -> signed state snapshot
var timers = new WeakMap(); // element -> {kind: timer or time}

// ---- helpers --------------------------------------------------------------------------

function emit(name, detail, target, pushed) {
  (target || document).dispatchEvent(new CustomEvent("spark:" + name, { bubbles: true, detail: detail }));
  (handlers[name] || []).slice().forEach(function (fn) {
    try { fn(detail); } catch (e) { if (window.console) console.error(e); }
  });
  if (debug && !pushed) console.debug("[azu-spark]", name, redact(detail)); // an event the app pushed carries its data: never traced
}

// ---- observability ----------------------------------------------------------------------
//
// Telemetry (state, rtt, timing, delivery) costs a handful of integer increments while nobody
// listens: the detail object and the DOM event are made only for a name somebody subscribed to
// with AzuSpark.on (or while debug tracing is on), see observed(). stats() reads the counters.

var tally = { bytesIn: 0, bytesOut: 0, applied: 0, sent: 0, resent: 0, acked: 0, dropped: 0, reconnects: 0 };
var rtts = []; // the last 16 round trips
var beatId = 0;
var beatAt = 0;

function observed(name) {
  var list = handlers[name];
  return debug || (list !== undefined && list.length > 0);
}

// Counts a delivery step (sent, resent, acked, dropped) and tells the subscribers.
function delivered(phase, entry) {
  tally[phase]++;
  if (observed("delivery")) emit("delivery", { phase: phase, event: entry.message.event, eid: entry.message.eid });
}

function round(ms) { return Math.round(ms * 10) / 10; }

function median() {
  return rtts.length ? rtts.slice().sort(function (a, b) { return a - b; })[rtts.length >> 1] : null;
}

function sampleRtt(id) {
  if (id !== beatId || !beatAt) return;
  var ms = round(now() - beatAt);
  beatAt = 0;
  if (rtts.push(ms) > 16) rtts.shift();
  if (observed("rtt")) emit("rtt", { ms: ms, p50: median() });
}

// Only numbers, booleans and a few short words (states, reasons, codes, event names) are traced:
// every other value, a message, a token or a snapshot, shows as its type. (Payloads that the app
// pushes are not traced at all.)

function redact(detail) {
  var out = {};
  Object.keys(detail && typeof detail === "object" ? detail : {}).forEach(function (key) {
    var value = detail[key];
    out[key] = /^(from|to|reason|code|event|phase)$/.test(key) || typeof value === "number" || typeof value === "boolean" ? value : "<" + typeof value + ">";
  });
  return out;
}

/** @returns {SparkStats} */
function snapshot() {
  return {
    state: machine.state.name, attempts: machine.state.attempts,
    rtt: { last: rtts.length ? rtts[rtts.length - 1] : null, p50: median() },
    queue: { waiting: queue.length, unacked: pending.size },
    bytes: { in: tally.bytesIn, out: tally.bytesOut },
    patches: { applied: tally.applied },
    delivery: { sent: tally.sent, resent: tally.resent, acked: tally.acked, dropped: tally.dropped },
    reconnects: tally.reconnects
  };
}

// ---- accessibility ----------------------------------------------------------------------
//
// One polite live region, made on the first announcement (or the page's own element marked
// data-spark-live-region). It is hidden through CSSOM properties, which a strict style-src allows
// (a style attribute would not be), never takes focus, and says reconnecting / offline / stale /
// restored with the words of AzuSpark.configure({text}), data-spark-text-<key>, or English.
// aria-busy marks a root while one of its events is unanswered, but only after config.busyDelay.

var TEXT = {
  reconnecting: "Reconnecting...", offline: "Offline. Live updates are paused.",
  stale: "This page may be out of date.", restored: "Back online."
};
var HIDDEN = { position: "absolute", width: "1px", height: "1px", overflow: "hidden", clip: "rect(0 0 0 0)" };
var region = null;
var problem = ""; // the connection announcement that was made and not yet resolved
var speaking = 0;
var spoken = []; // messages waiting to be spoken, the first is being spoken
var waiting = {}; // key -> the timer of an announcement not yet made

function words(key) {
  var own = text[key];
  if (own === undefined) own = attr("text-" + key);
  return own === undefined || own === null ? TEXT[key] : own;
}

// Messages are spoken one after the other, none replaced: the region is blanked first, so the same
// words are read again, and set a moment later, because a live region is announced when its content
// changes, not when it appears.
function say(message) {
  if (spoken.push(message) === 1) speak();
}

function speak() {
  if (!region || !region.isConnected) {
    // The page's own region, unless it is inside a component: a patch could overwrite it.
    region = Array.prototype.filter.call(document.querySelectorAll("[data-spark-live-region]"), function (el) { return !el.closest("[data-spark-id]"); })[0];
    if (!region) {
      region = document.createElement("div");
      region.setAttribute("role", "status");
      region.setAttribute("aria-live", "polite");
      region.className = "azu-spark-live";
      Object.assign(region.style, HIDDEN);
      document.body.appendChild(region);
    }
  }
  region.textContent = "";
  speaking = setTimeout(function () {
    region.textContent = spoken[0];
    speaking = setTimeout(function () {
      spoken.shift();
      if (spoken.length) speak();
    }, 100);
  }, 100);
}

// Each key has its own timer: a stale event never cancels a pending connection announcement.
function announce(key, delay) {
  if (!config.live || key === problem) return;
  if (key === "restored") {
    quiet();
    var back = problem;
    problem = "";
    if (!back) return;
  }
  clearTimeout(waiting[key]);
  waiting[key] = setTimeout(function () {
    if (key === "reconnecting" || key === "offline") problem = key;
    var message = words(key);
    if (message || key === "restored") say(message);
  }, delay);
}

/** Forgets what was announced and what waits to be (for the tests). */
export function resetAnnouncements() {
  Object.keys(waiting).forEach(function (key) { clearTimeout(waiting[key]); });
  quiet(true);
  problem = "";
  region = null;
}

// Cancels what waits to be announced: the connection messages, and with *all* the rest.
function quiet(all) {
  clearTimeout(waiting.reconnecting);
  clearTimeout(waiting.offline);
  if (all) {
    clearTimeout(waiting.stale);
    clearTimeout(speaking);
    spoken = [];
  }
}

function feel(to) {
  var name = to.name;
  if (name === "open") announce("restored", 0);
  else if (name === "offline") announce("offline", 100);
  else if (name === "backoff") announce("reconnecting", 1000);
  else if (/^(hidden-idle|stopped|idle)$/.test(name)) quiet(true); // nobody is looking, or nobody is listening
}

function startBusy(root) {
  var slot = root.sparkBusy || (root.sparkBusy = { n: 0 });
  if (slot.n++ === 0) slot.timer = setTimeout(function () { root.setAttribute("aria-busy", "true"); }, config.busyDelay);
}

function endBusy(root) {
  var slot = root.sparkBusy;
  if (--slot.n > 0) return;
  clearTimeout(slot.timer);
  root.removeAttribute("aria-busy");
}

function setStatus(next, state) {
  if (status === next) return;
  status = next;
  document.documentElement.setAttribute("data-spark-status", next);
  emit(next, { attempts: state.attempts });
}

function now() {
  return performance.now(); // monotonic: unaffected by clock changes, comparable with timer gaps
}

function byId(id) {
  return document.querySelector('[data-spark-id="' + String(id).replace(/["\\]/g, "\\$&") + '"]');
}

function roots(scope) {
  return Array.prototype.slice.call((scope || document).querySelectorAll("[data-spark-root]"));
}

function socketUrl() {
  var url = new URL(config.path, location.href);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  return url.toString();
}

function pageParams() {
  var params = {};
  new URLSearchParams(location.search).forEach(function (value, key) { params[key] = value; });
  return params;
}

// ---- delivery ---------------------------------------------------------------------------
//
// Every event is numbered (`eid`) when it is first sent and keeps its number until the server
// acknowledges it, so a resend after a reconnect is recognised: the server applies an `eid` once.
// Unacknowledged events stay in `pending`; when the connection is lost they go back to the front
// of the queue, in order, and are sent again once the page has rejoined (at least once).
//
// Order: the events of one root reach the server in the order they were made. An event that
// replaces a value (text input) waits while an earlier one for the same control is in flight, and
// anything made after it for that root waits behind it; meanwhile newer values of the same
// control merge into it, so the latest value wins and no stale one is overtaken. Value events of
// different controls may swap places among themselves; nothing else is ever reordered.

// Sends *entry* now; false when there is no open socket.
function send(entry) {
  // Not before the server greeted us and every page root has rejoined: earlier, the target does not exist yet.
  if (machine.state.name !== "open") return false;
  var id = ++nextId;
  entry.message.id = id;
  var again = !!entry.message.eid;
  if (!again) entry.message.eid = ++lastEid;
  if (transmit(entry.message)) {
    delivered(again ? "resent" : "sent", entry);
    entry.sentAt = now();
    pending.set(id, entry);
  } else release(entry); // too large for the server: reported as an error, never retried
  return true;
}

// Ends the loading state of *entry* (once).
function release(entry) {
  var undo = entry.undo;
  entry.undo = null;
  if (undo) undo();
  if (entry.rootEl) {
    endBusy(entry.rootEl);
    entry.rootEl = null;
  }
}

// Forgets *entry* without delivering it, and says so.
function drop(entry, reason) {
  release(entry);
  delivered("dropped", entry);
  emit("event_dropped", { event: entry.message.event, reason: reason });
  if (reason !== "stopped") announce("stale", 100);
}

// Adds *entry* to the queue, or merges it into a waiting event of its root that carries the same
// value of the same control (the newer value replaces the older one in place). Only value events of
// other controls may lie in between: any other event, or one that was sent once (it may have been
// applied, its number must keep standing for what it carried), is a barrier. Returns the entry
// that holds the event.
function enqueue(entry) {
  for (var i = queue.length - 1; entry.key && i >= 0; i--) {
    var other = queue[i];
    if (other.root !== entry.root) continue;
    if (!other.key || other.message.eid) break;
    if (other.key !== entry.key) continue;
    other.message.payload = entry.message.payload;
    other.at = entry.at;
    release(entry);
    return other;
  }
  queue.push(entry);
  return entry;
}

// Waiting events and unacknowledged ones share one bound; the oldest goes first.
function trim() {
  while (queue.length + pending.size > config.queueMax) {
    var oldest = pending.keys().next().value; // the oldest sent one, or the oldest waiting one: whichever is older
    var entry = pending.get(oldest);
    if (entry && (!queue.length || entry.at <= queue[0].at)) pending.delete(oldest); else entry = queue.shift();
    drop(entry, "queue_full");
    emit("error", { code: "queue_full", message: "too many unacknowledged events" });
  }
}

var awaitingPaint = new Set(); // keys of answered events whose patches are not painted yet

function inFlight(key) {
  var found = awaitingPaint.has(key);
  pending.forEach(function (entry) { if (entry.key === key) found = true; });
  return found;
}

function joinsSettled() {
  if (joining.size > 0) return;
  machine.dispatch({ type: "joins_settled" });
  pump();
}

// Sends what may be sent, in order: not an event that is too old, nor one that has to wait for
// an earlier value of its control (and then nothing after it for the same root).
function pump() {
  if (machine.state.name !== "open") return;
  var waiting = queue;
  var held = {};
  var current = now();
  queue = [];
  waiting.forEach(function (entry) {
    if (current - entry.at > config.queueMaxAge) return drop(entry, "expired");
    if (held[entry.root] || (entry.key && inFlight(entry.key))) {
      held[entry.root] = true;
      queue.push(entry);
    } else if (!send(entry)) queue.push(entry);
  });
}

function transmit(message) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return false;
  var text = JSON.stringify(message);
  if (hello && text.length > hello.max_size) {
    emit("error", { code: "too_large", message: "message exceeds " + hello.max_size + " bytes" });
    return false;
  }
  ws.send(text);
  tally.bytesOut += text.length;
  return true;
}

// ---- connection state machine -----------------------------------------------------------
//
// The connection is always in exactly one state:
//
//   idle         not connected, nothing scheduled (before start, or the page was hidden into the bfcache)
//   connecting   a socket exists and the server has not greeted us yet
//   joining      greeted; waiting for the server to answer the join of every page root
//   open         joined; events are sent
//   closing      we asked the socket to close and wait for it (then: where it leads)
//   backoff      the connection was lost; waiting to try again
//   offline      the browser has no network; waiting for `online`
//   hidden-idle  closed on purpose (code 1000) after the tab was hidden for config.idleMs; the tab's return rejoins
//   stopped      stopped for good until connect() (disconnect(), or the page can never join)
//
// `next(state, event)` is a pure function: it returns the new state and the effects to run. The
// runner (createMachine) executes the effects and owns every timer: entering a state cancels the
// timers of the one it left, so a timer can never outlive its state. docs/reference/spark-client.md
// has the diagram.

export var STATES = ["idle", "connecting", "joining", "open", "closing", "backoff", "offline", "hidden-idle", "stopped"];
export var EVENTS = [
  "connect", "stop", "pageshow", "pagehide", "online", "offline", "visible", "hidden", "hide_idle",
  "hello", "joins_pending", "joins_settled", "stable", "closed", "dead", "backoff_elapsed"
];

// How long a state may wait for its way out (milliseconds).
var TIMING = { connect: 10000, join: 10000, close: 3000 };

function st(name, attempts, then) {
  var state = { name: name, attempts: attempts };
  if (then) state.then = then;
  return state;
}

function go(state, effects) {
  return { state: state, effects: effects || [] };
}

function after(name, ms, event) {
  return { type: "after", name: name, ms: ms, event: event };
}

function connectNow(attempts) {
  return go(st("connecting", attempts), [{ type: "open" }, after("connect", TIMING.connect, { type: "dead", reason: "connect timeout" })]);
}

function connectFresh() { return connectNow(0); }
function stopped(state) { return go(st("stopped", state.attempts)); }
function paused(state) { return go(st("idle", state.attempts)); }

function closeThen(state, then, code, reason) {
  return go(st("closing", state.attempts, then), [
    { type: "close", code: code, reason: reason, detach: false },
    after("close", TIMING.close, { type: "closed", code: 1006, reason: "close timeout" })
  ]);
}

// The socket is gone (`closed`) or abandoned (`dead`): clean up, then wait (or reconnect) unless offline.
function lose(state, event, abandon) {
  var effects = [];
  if (abandon) effects.push({ type: "close", code: 4000, reason: event.reason, detach: true });
  effects.push({ type: "teardown", code: abandon ? 4000 : event.code, reason: event.reason });
  if (event.online === false) return go(st("offline", state.attempts), effects);
  effects.push({ type: "backoff", attempt: state.attempts });
  return go(st("backoff", state.attempts + 1), effects);
}

function lostSocket(state, event) { return lose(state, event, false); }
function droppedSocket(state, event) { return lose(state, event, true); }

function networkLost(state) {
  return go(st("offline", state.attempts), [
    { type: "close", code: 4000, reason: "offline", detach: true },
    { type: "teardown", code: 4000, reason: "offline" }
  ]);
}

// Every state that holds a socket reacts the same way to these.
var WITH_SOCKET = {
  closed: lostSocket,
  dead: droppedSocket,
  offline: networkLost,
  stop: function (state) { return closeThen(state, "stopped", 1000, "stopped"); },
  hide_idle: function (state) { return closeThen(state, "hidden-idle", 1000, "hidden idle"); },
  pagehide: function (state) { return closeThen(state, "idle", 1000, "page closed"); }
};

var BEATING = [{ type: "heartbeat" }];
var JOIN_WATCH = after("join", TIMING.join, { type: "dead", reason: "join timeout" });

function probe(state) { return go(state, [{ type: "probe" }]); }
function forget(state) { return go(st(state.name, 0)); } // the backoff starts over: the connection proved stable

function withSocket(own) {
  return Object.assign({}, WITH_SOCKET, own);
}

// "resuming" is "connecting" for a tab that returned from an idle close: its attempts stand.
function wakeAfterClose(state) { return state.then === "hidden-idle" || state.then === "resuming" ? go(st("closing", state.attempts, "resuming")) : go(state); }

function afterClose(state, event) {
  var teardown = { type: "teardown", code: event.code, reason: event.reason };
  if (state.then === "connecting" || state.then === "resuming") {
    var attempts = state.then === "resuming" ? state.attempts : 0;
    return go(st("connecting", attempts), [teardown].concat(connectNow(attempts).effects));
  }
  return go(st(state.then, state.attempts), [teardown]);
}

// Also the way back from an idle close: the attempts stand, so a server that is down keeps getting longer delays.
function retry(state) { return connectNow(state.attempts); }

// The network is back: retry after the first (smallest) jittered delay, not at once, so captive
// portals, flapping Wi-Fi and a fleet of clients coming online together do not stampede. The
// attempts are kept: only a connection that proves stable resets them.
function networkBack(state) {
  return go(st("backoff", state.attempts), [{ type: "backoff", attempt: 0 }]);
}

function resume(state, event) { return event.online === false ? go(state) : retry(state); }

/** The transition table: TRANSITIONS[state][event] is (state, event) -> {state, effects}. A missing entry ignores the event. */
export var TRANSITIONS = {
  idle: { connect: connectFresh, pageshow: connectFresh, stop: stopped },
  connecting: withSocket({
    hello: function (state) {
      return go(st("joining", state.attempts), [{ type: "opened" }].concat(BEATING, [JOIN_WATCH]));
    }
  }),
  joining: withSocket({ joins_settled: function (state) { return go(st("open", state.attempts), BEATING); }, stable: forget, visible: probe, online: probe }),
  open: withSocket({
    joins_pending: function (state) {
      return go(st("joining", state.attempts), BEATING.concat([JOIN_WATCH]));
    },
    stable: forget,
    visible: probe,
    online: probe // after a sleep or a network change the socket may be dead without anyone telling us
  }),
  closing: {
    closed: afterClose,
    dead: afterClose,
    stop: function (state) { return go(st("closing", state.attempts, "stopped")); },
    pagehide: function (state) { return go(st("closing", state.attempts, state.then === "stopped" ? "stopped" : "idle")); },
    connect: function (state) { return state.then === "hidden-idle" || state.then === "resuming" ? wakeAfterClose(state) : go(st("closing", state.attempts, "connecting")); },
    // The tab went idle and came back before the close finished (or the other way round): follow it.
    visible: wakeAfterClose,
    hide_idle: function (state) { return state.then === "connecting" || state.then === "resuming" ? go(st("closing", state.attempts, "hidden-idle")) : go(state); },
    // Restored from the back/forward cache before the close finished: connect once it has (a stopped client stays stopped).
    pageshow: function (state) { return state.then === "stopped" ? go(state) : go(st("closing", state.attempts, "connecting")); }
  },
  backoff: {
    backoff_elapsed: retry,
    connect: retry,
    visible: resume, // a hidden tab's timers run late: try now, but keep the attempts so the delays keep growing
    online: networkBack,
    offline: function (state) { return go(st("offline", state.attempts)); },
    hide_idle: function (state) { return go(st("hidden-idle", state.attempts)); },
    stop: stopped,
    pagehide: paused
  },
  offline: { online: networkBack, connect: retry, visible: resume, hide_idle: function (state) { return go(st("hidden-idle", state.attempts)); }, stop: stopped, pagehide: paused },
  "hidden-idle": { visible: retry, connect: retry, pageshow: retry, stop: stopped, pagehide: paused },
  stopped: { connect: connectFresh }
};

/**
 * The pure transition function.
 * @param {{name: string, attempts: number, then?: string}} state
 * @param {{type: string, online?: boolean, code?: number, reason?: string}} event
 * @returns {{state: object, effects: object[]}}
 */
export function next(state, event) {
  var row = TRANSITIONS[state.name];
  var rule = row && row[event.type];
  return rule ? rule(state, event) : go(state);
}

/**
 * The public status (data-spark-status) of a state.
 * @param {{name: string, attempts: number}} state
 * @returns {SparkStatus}
 */
export function statusOf(state) {
  if (state.name === "connecting") return state.attempts > 0 ? "reconnecting" : "connecting";
  return state.name === "joining" || state.name === "open" ? "connected" : "disconnected";
}

// Full jitter: a uniformly random delay between 0 and an exponentially growing, capped ceiling,
// so clients that lost the same server do not come back together.
/**
 * Delay before reconnect attempt number *attempt* (0 based), in milliseconds.
 * @param {number} attempt
 * @param {() => number} [random] uniform in [0, 1)
 * @returns {number}
 */
export function backoff(attempt, random) {
  var ceiling = Math.min(config.backoffMax, config.backoffMin * Math.pow(2, attempt));
  return Math.round((random || Math.random)() * ceiling);
}

// The server proposes the heartbeat interval and drops a connection silent for longer than its
// idle timeout. Only a supported interval is ever used: the largest that is not above the
// proposal (never slower than the server expects), at least 1 s, so a missing, non-numeric or
// absurd value cannot become a busy timer (NaN fires at once) or one that never fires.
var HEARTBEAT_INTERVALS = [1000, 2000, 5000, 10000, 20000, 30000, 60000];

/**
 * The supported heartbeat interval for the server's proposal, in milliseconds.
 * @param {unknown} proposed
 * @returns {number}
 */
export function heartbeatInterval(proposed) {
  var wanted = Number(proposed) || 20000;
  var chosen = HEARTBEAT_INTERVALS[0];
  for (var i = 0; i < HEARTBEAT_INTERVALS.length; i++) {
    if (HEARTBEAT_INTERVALS[i] <= wanted) chosen = HEARTBEAT_INTERVALS[i];
  }
  return chosen;
}

/**
 * Whether a connection that has been silent for *silence* ms is dead. A half open connection never
 * fires `close`, so silence is the only sign. But a throttled or frozen tab runs its watchdog late
 * (*gap* is the time since its previous run, *period* how often it should run), and frames may sit
 * unread behind it: then the silence proves nothing and the server is asked instead. After a
 * system sleep the monotonic clock may not have advanced at all; *jumped* is how much more the wall
 * clock advanced than the monotonic one, and a large jump also means the server is asked.
 * @param {{silence: number, gap: number, interval: number, period: number, jumped?: number}} measure all in milliseconds
 * @returns {"alive" | "suspect" | "dead"}
 */
export function heartbeatVerdict(measure) {
  if ((measure.jumped || 0) > measure.period * 2) return "suspect";
  if (measure.silence <= measure.interval * 2.5) return "alive";
  return measure.gap > measure.period * 2 ? "suspect" : "dead";
}

/**
 * Runs the machine: executes the effects of each transition and owns the timers. Everything it
 * touches comes in through *deps*, so it runs against a fake clock in tests.
 * @param {object} deps timers {setTimeout, clearTimeout, setInterval, clearInterval}, now() (monotonic), wall() (Date.now),
 *   random(), online(),
 *   interval() (heartbeat ms), beat() (sends a heartbeat, true when sent), tick(), status(name, state),
 *   and the host effects open, close, teardown, opened, backingOff (and changed(from, to, event), optional)
 * @param {object} [settings] backoffMin, backoffMax, probeTimeout, stableAfter, idleMs (ms); without it the live config is used
 */
export function createMachine(deps, settings) {
  var cfg = settings ? Object.assign({}, config, settings) : config;
  var state = st("idle", 0);
  var timers = {};
  var inbox = [];
  var running = false;
  var lastFrameAt = 0;
  var lastWatchAt = 0;
  var lastWallAt = 0;
  var connectedAt = 0;
  var hiddenNow = false;
  var idleTimer = 0;

  // The idle window belongs to the tab, not to a state: it runs across reconnects while the tab stays hidden.
  function disarmIdle() {
    deps.timers.clearTimeout(idleTimer);
    idleTimer = 0;
  }

  function armIdle() {
    disarmIdle();
    if (cfg.idleMs > 0) idleTimer = deps.timers.setTimeout(function () { idleTimer = 0; machine.dispatch({ type: "hide_idle" }); }, cfg.idleMs);
  }

  function own(name, handle, clear) {
    cancel(name);
    timers[name] = function () { clear(handle); };
  }

  function cancel(name) {
    if (!timers[name]) return;
    timers[name]();
    delete timers[name];
  }

  function cancelAll() {
    Object.keys(timers).forEach(cancel);
  }

  function later(name, ms, work) {
    own(name, deps.timers.setTimeout(function () { delete timers[name]; work(); }, ms), deps.timers.clearTimeout);
  }

  function probe(retried) {
    var asked = deps.now();
    if (!deps.beat()) return;
    later("probe", cfg.probeTimeout, function () {
      if (lastFrameAt >= asked) return;
      // The timer itself ran late (a throttled tab): the answer may be queued behind it. Wait once more.
      if (!retried && deps.now() - asked > cfg.probeTimeout * 2) return probe(true);
      machine.dispatch({ type: "dead", reason: "heartbeat timeout" });
    });
  }

  function watch(interval, period) {
    var current = deps.now();
    var wall = deps.wall();
    var gap = current - lastWatchAt;
    var verdict = heartbeatVerdict({ silence: current - lastFrameAt, gap: gap, interval: interval, period: period, jumped: wall - lastWallAt - gap });
    lastWatchAt = current;
    lastWallAt = wall;
    deps.tick();
    if (verdict === "dead") return machine.dispatch({ type: "dead", reason: "heartbeat timeout" });
    if (verdict === "suspect") probe(false);
    if (state.attempts > 0 && current - connectedAt >= cfg.stableAfter) machine.dispatch({ type: "stable" });
  }

  function heartbeat() {
    var interval = deps.interval();
    var period = Math.min(interval, 5000);
    lastWatchAt = deps.now();
    lastWallAt = deps.wall();
    own("beat", deps.timers.setInterval(deps.beat, interval), deps.timers.clearInterval);
    own("watch", deps.timers.setInterval(function () { watch(interval, period); }, period), deps.timers.clearInterval);
  }

  function run(effect) {
    switch (effect.type) {
      case "after": later(effect.name, effect.ms, function () { machine.dispatch(effect.event); }); break;
      case "backoff": {
        var delay = backoff(effect.attempt, deps.random);
        deps.backingOff(delay, state.attempts);
        later("backoff", delay, function () { machine.dispatch({ type: "backoff_elapsed" }); });
        break;
      }
      case "heartbeat": heartbeat(); break;
      case "probe": probe(false); break;
      default: deps[effect.type](effect);
    }
  }

  function step(event) {
    var typed = event.online === undefined ? Object.assign({ online: deps.online() }, event) : event;
    if (typed.type === "hidden") { hiddenNow = true; armIdle(); }
    else if (typed.type === "visible") { hiddenNow = false; disarmIdle(); }
    else if (typed.type === "stop" || typed.type === "pagehide") disarmIdle();
    var result = next(state, typed);
    var previous = state;
    state = result.state;
    if (state.name !== previous.name) {
      cancelAll();
      if (previous.name === "connecting" && state.name === "joining") connectedAt = deps.now();
      if (hiddenNow && !idleTimer && state.name === "connecting") armIdle();
      deps.status(statusOf(state), state);
      if (deps.changed) deps.changed(previous, state, typed);
    }
    result.effects.forEach(run);
  }

  var machine = {
    get state() { return state; },
    /** Feeds an event to the machine (events raised by effects wait until the current one is done). */
    dispatch: function (event) {
      inbox.push(event);
      if (running) return;
      running = true;
      try { while (inbox.length > 0) step(inbox.shift()); } finally { running = false; }
    },
    /** Records that a frame arrived: the proof of life the heartbeat looks for. */
    frame: function () { lastFrameAt = deps.now(); },
    /** The number of timers that are running. */
    timers: function () { return Object.keys(timers).length; }
  };
  return machine;
}

var machine = createMachine({
  timers: {
    setTimeout: function (work, ms) { return setTimeout(work, ms); },
    clearTimeout: function (handle) { clearTimeout(handle); },
    setInterval: function (work, ms) { return setInterval(work, ms); },
    clearInterval: function (handle) { clearInterval(handle); }
  },
  now: now,
  wall: Date.now,
  random: Math.random,
  online: function () { return navigator.onLine !== false; },
  interval: function () { return heartbeatInterval(hello && hello.heartbeat); },
  beat: function () {
    beatId = ++nextId;
    beatAt = now();
    return transmit({ v: PROTOCOL, type: "heartbeat", id: beatId });
  },
  tick: expirePending,
  status: setStatus,
  open: openSocket,
  close: closeSocket,
  teardown: teardown,
  opened: function () { emit("open", { attempts: machine.state.attempts }); },
  changed: function (from, to, event) {
    if (observed("state")) emit("state", { from: from.name, to: to.name, reason: event.type, attempts: to.attempts });
    feel(to);
  },
  backingOff: function (delay, attempts) {
    tally.reconnects++;
    emit("backoff", { delay: delay, attempts: attempts });
    emit("reconnect", { delay: delay, attempts: attempts });
  }
});

// ---- the socket (effects of the machine) ------------------------------------------------

function openSocket() {
  var socket;
  try { socket = new WebSocket(socketUrl()); } catch (e) { return machine.dispatch({ type: "dead", reason: "cannot connect" }); }
  ws = socket;
  socket.onmessage = function (event) { if (ws === socket) receive(event.data); };
  socket.onclose = function (event) { if (ws === socket) machine.dispatch({ type: "closed", code: event.code, reason: event.reason }); };
  socket.onerror = function () { /* onclose follows */ };
}

// Closes the socket. An abandoned one (*detach*) is forgotten at once, not waited for: a dead
// peer never answers the close handshake.
function closeSocket(effect) {
  var socket = ws;
  if (!socket) return;
  if (effect.detach) ws = null;
  try { socket.close(effect.code, effect.reason); } catch (e) { /* already closed */ }
}

function teardown(effect) {
  ws = null;
  hello = null;
  joined.clear();
  joining.clear();
  cancelPending();
  emit("close", { code: effect.code, reason: effect.reason });
}

function joinRoots(scope) {
  var phase = machine.state.name;
  if (phase !== "joining" && phase !== "open") return; // the roots join when the server greets us
  roots(scope).forEach(function (root) {
    var id = root.getAttribute("data-spark-id");
    if (joined.has(id)) return;
    joined.add(id);
    var frame = { v: PROTOCOL, type: "join", id: ++nextId, token: root.getAttribute("data-spark-token"), params: pageParams() };
    if (snapshots.has(id)) frame.snapshot = snapshots.get(id);
    joining.set(frame.id, id);
    transmit(frame);
  });
  if (joining.size > 0 && phase === "open") machine.dispatch({ type: "joins_pending" });
}

// ---- incoming frames --------------------------------------------------------------------

function receive(text) {
  var message;
  machine.frame();
  tally.bytesIn += text.length;
  try { message = JSON.parse(text); } catch (e) { return; }
  switch (message.type) {
    case "hello":
      if (machine.state.name !== "connecting") break; // a stray greeting: nothing to join
      hello = message;
      machine.dispatch({ type: "hello" });
      joinRoots();
      joinsSettled();
      break;
    case "diff": applyDiff(message); break;
    case "reply": learnGeneration(message); answered(message.id); joinsSettled(); break;
    case "redirect": navigate(message.to, message.replace); break;
    case "heartbeat": sampleRtt(message.id); break;
    case "error": failed(message); break;
  }
  // The server names the event a frame answers: done with it, even if its reply never comes.
  if (message.ack) acknowledge(message.ack);
}

// The event is answered: it is no longer unacknowledged at once (a close before the next frame must
// not send it again, the snapshot that came with it already holds its effect), but the page shows it
// as done only after the patches that came with the answer.
function answered(id) {
  var entry = pending.get(id);
  pending.delete(id);
  if (entry) delivered("acked", entry);
  // The next value of its control waits for the paint: an older patch must not land over newer text.
  if (entry && entry.key) awaitingPaint.add(entry.key);
  afterPatches(function () {
    if (entry) {
      awaitingPaint.delete(entry.key);
      release(entry);
    }
    pump();
  });
  return entry;
}

// A reply to a join names the generation of the root's state; events made for it carry that name.
function learnGeneration(message) {
  var root = joining.get(message.id);
  joining.delete(message.id);
  if (root === undefined) return;
  if (message.gen) gens.set(root, message.gen); else gens.delete(root);
}

function acknowledge(eid) {
  pending.forEach(function (entry, id) { if (entry.message.eid === eid) answered(id); });
}

/**
 * Takes a diff frame: snapshots are kept at once, patches and pushed events wait for the next frame.
 * @param {{ patches?: {id: string, html: string}[], snapshots?: Record<string, string>, events?: {target: string, name: string, payload: unknown}[] }} message
 * @returns {void}
 */
export function applyDiff(message) {
  (message.patches || []).forEach(function (patch) { applyPatch(patch.id, patch.html); });
  Object.keys(message.snapshots || {}).forEach(function (id) { snapshots.set(id, message.snapshots[id]); });
  if ((message.events || []).length > 0) {
    later({ run: function () {
      message.events.forEach(function (push) {
        var element = byId(push.target);
        if (element) emit(push.name, push.payload, element, true);
      });
    } });
  }
}

function navigate(to, replace) {
  // Only addresses on this origin. Browsers drop tabs and newlines from a URL, so "/\t/host" is
  // "//host": resolve the address the way the browser will and compare origins instead of
  // looking at its first characters.
  if (typeof to !== "string") return;
  var target;
  try { target = new URL(to, location.origin); } catch (e) { return; }
  if (target.origin !== location.origin) return;
  var path = target.pathname + target.search + target.hash;
  if (replace) location.replace(path); else location.assign(path);
}

function failed(message) {
  var entry = answered(message.id);
  if (entry && (message.code === "stale_event" || message.code === "rate_limited")) {
    emit("event_dropped", { event: entry.message.event, reason: message.code === "stale_event" ? "stale" : "rate_limited" });
    announce("stale", 100);
  }
  var root = joining.get(message.id);
  joining.delete(message.id);
  emit("error", { code: message.code, message: message.message, id: message.id });
  if (message.code === "invalid_snapshot" && root) {
    // The saved state cannot be used (expired, tampered, or the app changed): start the view afresh.
    snapshots.delete(root);
    joined.delete(root);
    joinRoots();
  }
  joinsSettled();
  if (message.code === "invalid_token" || message.code === "rejected") {
    // The page can never join (expired token, refused by mount): stop retrying until reload.
    emit("expired", { code: message.code });
    if (message.code === "invalid_token") stop();
  }
}

// ---- DOM patching -----------------------------------------------------------------------
//
// Patches are applied in batches, one per animation frame: first everything the batch needs to
// read (focus, selection, scroll offsets), then every write, then the restore. A small keyed morph
// (below) edits the live nodes in place, so what the user is doing survives: a node is only
// replaced, never rebuilt from a string, and a control keeps what was typed unless the server
// changed the value.

var frame = []; // jobs for the next frame: {id?, run}
var fallback = 0; // the timer that flushes when no animation frame comes
var composing = null; // the element an IME is composing in
var touched = new WeakSet(); // <details>/<dialog> the user opened or closed
var served = new WeakMap(); // <details>/<dialog> -> the `open` the server sent last

function later(job) {
  frame.push(job);
  if (frame.length > 1) return;
  window.requestAnimationFrame(flushPatches);
  fallback = setTimeout(flushPatches, 50); // a hidden tab gets no animation frames (and throttled timers: see visibilitychange)
}

function afterPatches(work) {
  if (frame.length > 0) later({ run: work }); else work();
}

/**
 * Queues a patch for the component *id*: its content becomes *html*.
 * @param {string} id
 * @param {string} html
 * @returns {void}
 */
export function applyPatch(id, html) {
  later({ id: id, run: function () { patchNow(id, html); } });
}

/**
 * Runs the queued jobs: reads first, then every write, then restores focus, selection and scroll.
 * @returns {void}
 */
export function flushPatches() {
  clearTimeout(fallback); // a stale timer must not flush the next batch early
  var jobs = frame;
  frame = [];
  if (jobs.length === 0) return;
  var kept = { scrolls: [], focus: null };
  var started = now();
  var patches = 0;
  var guard = function (work) {
    try { work(); } catch (e) { emit("error", { code: "patch_failed", message: String(e && e.message || e) }); }
  };
  guard(function () { kept = remember(jobs.map(function (job) { return job.id === undefined ? null : byId(job.id); }).filter(Boolean)); });
  jobs.forEach(function (job) {
    if (job.id !== undefined) patches++;
    guard(job.run);
  });
  guard(function () { recall(kept); });
  if (patches > 0) {
    tally.applied += patches;
    if (observed("timing")) emit("timing", { patches: patches, ms: now() - started });
  }
}

// Layout reads, all before the first write: scroll offsets inside the patched components, and the
// focused control with its caret (or, in an editable region, its selection).
function remember(targets) {
  var kept = { scrolls: [], focus: null };
  var active = document.activeElement;
  targets.forEach(function (target) {
    [target].concat(Array.prototype.slice.call(target.querySelectorAll("*"))).forEach(function (el) {
      if (el.scrollTop || el.scrollLeft) kept.scrolls.push([el, el.scrollTop, el.scrollLeft]);
    });
  });
  if (active && targets.some(function (target) { return target.contains(active); })) {
    var selection = active.isContentEditable && window.getSelection && window.getSelection();
    kept.focus = {
      el: active, start: active.selectionStart, end: active.selectionEnd, direction: active.selectionDirection,
      range: selection && selection.rangeCount ? selection.getRangeAt(0).cloneRange() : null
    };
  }
  return kept;
}

function recall(kept) {
  kept.scrolls.forEach(function (saved) {
    var el = saved[0];
    if (!el.isConnected) return;
    if (el.scrollTop !== saved[1]) el.scrollTop = saved[1];
    if (el.scrollLeft !== saved[2]) el.scrollLeft = saved[2];
  });
  var focus = kept.focus;
  if (!focus || !focus.el.isConnected) return;
  if (document.activeElement !== focus.el) focus.el.focus({ preventScroll: true });
  try {
    if (typeof focus.start === "number") focus.el.setSelectionRange(focus.start, focus.end, focus.direction || undefined);
  } catch (e) { /* a control type without a selection */ }
  if (focus.range && focus.range.startContainer.isConnected) {
    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(focus.range);
  }
}

function patchNow(id, html) {
  var element = byId(id);
  if (!element) return;
  var fragment = parsePatch(html);
  sanitize(fragment, element.closest("[" + OPT_IN + "]") !== null);
  // Child components that did not change are not part of this patch: keep their live elements.
  var live = new Map();
  Array.prototype.forEach.call(element.querySelectorAll("[data-spark-id]"), function (child) {
    live.set(child.getAttribute("data-spark-id"), child);
  });
  morphChildren(element, fragment, live);
  element.removeAttribute("data-spark-slot");
  emit("patch", { id: id }, element);
}

// What the user is doing right now in *el*: it has focus, or an IME is composing in it.
function busy(el) {
  return el.contains(document.activeElement) || (composing !== null && el.contains(composing));
}

var policyFor;
var policy;

// Under `require-trusted-types-for 'script'` parsing a string is a sink: only the named policy
// `azu-spark` may feed it. It exists to build an inert document that sanitize() cleans before any
// node reaches the page, it is not exposed, and it has no createScript or createScriptURL.
function trusted(html) {
  var types = window.trustedTypes;
  if (types !== policyFor) {
    policyFor = types;
    policy = null;
    try {
      policy = types ? types.createPolicy("azu-spark", { createHTML: function (value) { return value; } }) : null;
    } catch (e) {
      // Not listed in the CSP trusted-types directive, or the name is taken (the script was loaded twice).
      if (window.console) console.warn("azu-spark: cannot create the Trusted Types policy 'azu-spark': " + e.message);
    }
  }
  return policy ? policy.createHTML(html) : html;
}

// Parses a patch in an inert document: no script runs and no resource loads until the
// sanitised nodes are moved into the page. Wrapping it in <template> makes the parser
// accept fragments that only make sense in context (table rows, list items, options).
/**
 * Parses a patch into an inert fragment.
 * @param {string} html
 * @returns {DocumentFragment}
 */
export function parsePatch(html) {
  var doc = new DOMParser().parseFromString(trusted("<template>" + html + "</template>"), "text/html");
  var template = doc.querySelector("template");
  return template ? template.content : document.createDocumentFragment();
}

// Defence in depth for the HTML the server sends. The server escapes what it renders, and
// components bind events with data-spark-* attributes that this client delegates, so
// nothing legitimate needs a script element, an inline handler or a script URL: drop them,
// so that a hole on the server side (or a hostile frame) cannot become script execution here.
var BLOCKED_ELEMENTS = "script,iframe,frame,frameset,object,embed,applet,base,meta,link";
var URL_ATTRIBUTES = ["href", "src", "xlink:href", "action", "formaction", "data", "poster", "background"];

/**
 * Whether an attribute value is a URL that would run script (or load data) when followed.
 * @param {unknown} value
 * @param {string} name attribute name, lower case
 * @returns {boolean}
 */
export function scriptUrl(value, name) {
  // Browsers ignore ASCII whitespace and control characters inside a scheme.
  var scheme = String(value).replace(/[\u0000-\u0020]/g, "").toLowerCase();
  if (/^(javascript|vbscript):/.test(scheme)) return true;
  return /^data:/.test(scheme) && !(name === "src" && /^data:image\/(png|gif|jpe?g|webp|avif);/.test(scheme));
}

// SVG animation can set href (and event handler attributes) to a script URL after sanitising.
function animatesLink(node) {
  return /^(animate|set)$/i.test(node.nodeName) && /^(href|xlink:href|on)/i.test(node.getAttribute("attributeName") || "");
}

// Scripts of a patch do not run once moved into the page (the parser marked them started). A root that
// opted in (data-spark-allow-scripts) gets fresh copies, which do; without opt-in they are dropped.
// Needs 'unsafe-inline' or a nonce, and is refused by Trusted Types: then the script is dropped too.
function revive(old) {
  try {
    var fresh = document.createElement("script");
    Array.prototype.forEach.call(old.attributes, function (attr) { fresh.setAttribute(attr.name, attr.value); });
    fresh.text = old.textContent;
    old.replaceWith(fresh);
  } catch (e) { old.remove(); }
}

// A form that posts to another origin would hand the user's data away: only this origin is a target.
function foreignTarget(name, value) {
  if (name !== "action" && name !== "formaction") return false;
  try { return new URL(value, document.baseURI).origin !== location.origin; } catch (e) { return true; }
}

/**
 * Removes blocked elements, event handler attributes and script URLs from *root*, in place.
 * @param {ParentNode} root
 * @param {boolean} [scripts] keep scripts, as copies that can run (the root opted in)
 * @returns {void}
 */
export function sanitize(root, scripts) {
  Array.prototype.forEach.call(root.querySelectorAll(scripts ? BLOCKED_ELEMENTS.replace("script,", "") : BLOCKED_ELEMENTS), function (node) { node.remove(); });
  if (scripts) Array.prototype.forEach.call(root.querySelectorAll("script"), revive);
  Array.prototype.forEach.call(root.querySelectorAll("animate,set"), function (node) { if (animatesLink(node)) node.remove(); });
  // The content of a nested <template> is a separate fragment that querySelectorAll does not enter.
  Array.prototype.forEach.call(root.querySelectorAll("template"), function (node) { sanitize(node.content, scripts); });
  Array.prototype.forEach.call(root.querySelectorAll("*"), function (node) {
    Array.prototype.slice.call(node.attributes).forEach(function (attr) {
      var name = attr.name.toLowerCase();
      if (name.indexOf("on") === 0 || name === "srcdoc" || name === OPT_IN || foreignTarget(name, attr.value) ||
          (URL_ATTRIBUTES.indexOf(name) >= 0 && scriptUrl(attr.value, name))) node.removeAttribute(attr.name);
    });
  });
}

function keyOf(node) {
  if (node.nodeType !== 1) return null;
  var key = node.getAttribute("data-spark-id") || node.getAttribute("data-spark-key") || node.getAttribute("id"); // not .id: <input name=id> clobbers it
  return key ? node.nodeName + "\0" + key : null;
}

// Longest run of children that already are in the wanted order: those stay, the others move.
function stable(positions) {
  var tails = [];
  var before = [];
  positions.forEach(function (position, i) {
    if (position < 0) return;
    var low = 0;
    var high = tails.length;
    while (low < high) {
      var middle = (low + high) >> 1;
      if (positions[tails[middle]] < position) low = middle + 1; else high = middle;
    }
    before[i] = low > 0 ? tails[low - 1] : -1;
    tails[low] = i;
  });
  var keep = new Set();
  for (var i = tails.length > 0 ? tails[tails.length - 1] : -1; i >= 0; i = before[i]) keep.add(i);
  return keep;
}

// Moves *node* to just before *ref*. moveBefore keeps focus, scroll, playback and iframes alive.
function place(parent, node, ref) {
  if (node.parentNode === parent && node.nextSibling === ref) return;
  if (node.isConnected && parent.moveBefore) {
    try { return parent.moveBefore(node, ref); } catch (e) { /* fall through to insertBefore */ }
  }
  parent.insertBefore(node, ref);
}

// Children match by key (data-spark-id, data-spark-key, id), unkeyed ones by position; a key that
// is gone is inserted, a node nobody wants is removed, and only nodes outside the longest
// already-ordered run move.
function sameKind(a, b) {
  return a.nodeType === b.nodeType && a.nodeName === b.nodeName;
}

function morphChildren(from, to, live) {
  var old = Array.prototype.slice.call(from.childNodes);
  var wanted = Array.prototype.slice.call(to.childNodes);
  var keyed = new Map();
  var loose = [];
  var at = new Map();
  var next = 0;
  old.forEach(function (node, i) {
    var key = keyOf(node);
    at.set(node, i);
    if (key === null) loose.push(node); else if (!keyed.has(key)) keyed.set(key, node);
  });
  var claimed = new Set();
  var matches = wanted.map(function (want, i) {
    var key = keyOf(want);
    var node = null;
    if (key !== null) {
      node = keyed.get(key) || null;
      keyed.delete(key);
      if (want.hasAttribute("data-spark-slot") && live.has(want.getAttribute("data-spark-id"))) node = live.get(want.getAttribute("data-spark-id"));
    } else {
      // A mismatch is an insertion when the following wanted node fits the old node, else a deletion: skip what the server dropped.
      var from = next;
      var after = wanted.slice(i + 1).filter(function (w) { return keyOf(w) === null; })[0];
      if (!(loose[next] && after && sameKind(loose[next], after))) {
        while (from < loose.length && !sameKind(loose[from], want)) from++;
      }
      if (from < loose.length && sameKind(loose[from], want)) { node = loose[from]; next = from + 1; }
    }
    if (node) claimed.add(node);
    return node;
  });
  matches.forEach(function (node, i) { if (node) morphNode(node, wanted[i], live); });
  var keep = stable(matches.map(function (node) { return node && at.has(node) ? at.get(node) : -1; }));
  var ref = null;
  for (var i = wanted.length - 1; i >= 0; i--) {
    var node = matches[i] || wanted[i];
    if (!matches[i]) adoptSlots(node, live);
    if (!keep.has(i)) place(from, node, ref);
    ref = node;
  }
  old.forEach(function (node) { if (!claimed.has(node) && node.parentNode === from) from.removeChild(node); });
}

// A new subtree can wrap a child component that did not change: its slot becomes the live element.
function adoptSlots(node, live) {
  if (node.nodeType !== 1) return;
  Array.prototype.forEach.call(node.querySelectorAll("[data-spark-slot]"), function (slot) {
    var child = live.get(slot.getAttribute("data-spark-id"));
    if (child) slot.replaceWith(child);
  });
}

function morphNode(from, to, live) {
  if (from.nodeType !== 1) {
    if (from.nodeValue !== to.nodeValue) from.nodeValue = to.nodeValue;
    return;
  }
  // Component wrappers are owned by their own patches; spark-ignore subtrees by nobody.
  if (from.hasAttribute("data-spark-id") || from.hasAttribute("spark-ignore")) return;
  morphAttributes(from, to);
  if (from.nodeName === "TEXTAREA") morphTextarea(from, to);
  else if (!(from.isContentEditable && busy(from))) morphChildren(from, to, live);
}

// Attributes that only seed a property the user then changes (value, checked, selected).
var SEEDS = { INPUT: ["value", "checked"], OPTION: ["selected"] };
var OPENABLE = /^(DETAILS|DIALOG)$/;
var OPT_IN = "data-spark-allow-scripts";

function morphAttributes(from, to) {
  var names = new Set();
  [from, to].forEach(function (el) {
    Array.prototype.forEach.call(el.attributes, function (attr) { names.add(attr.name); });
  });
  var openable = OPENABLE.test(from.nodeName);
  if (openable) reopen(from, to.hasAttribute("open"));
  names.forEach(function (name) {
    var was = from.getAttribute(name);
    var now = to.getAttribute(name);
    if (was === now || (openable && name === "open") || name === OPT_IN) return; // the opt-in is the mount's, never a patch's
    var seeds = (SEEDS[from.nodeName] || []).indexOf(name) >= 0;
    // Typing wins: a focused or composing control keeps its text, and gets the server's value in a later patch.
    if (seeds && name === "value" && busy(from) && from.value !== (now || "")) return;
    if (now === null) from.removeAttribute(name); else from.setAttribute(name, now);
    if (seeds) {
      try { from[name] = name === "value" ? now || "" : now !== null; } catch (e) { /* a file input */ }
    }
  });
}

function morphTextarea(from, to) {
  var now = to.textContent;
  if (from.textContent === now || (busy(from) && from.value !== now)) return;
  from.textContent = now;
  from.value = now;
}

// <details> and <dialog> belong to the user once they used them: the server's `open` applies only
// when it differs from what the server said last time.
function reopen(el, open) {
  var before = served.get(el);
  served.set(el, open);
  if (before === undefined ? touched.has(el) : before === open) return;
  if (!open && el.close) el.close(); else el.toggleAttribute("open", open);
}

function watchUser() {
  var mark = function (event) { touched.add(event.target); };
  document.addEventListener("toggle", mark, true);
  document.addEventListener("close", mark, true);
  document.addEventListener("visibilitychange", flushPatches); // background timers are throttled
  document.addEventListener("compositionstart", function (event) { composing = event.target; }, true);
  document.addEventListener("compositionend", function (event) {
    composing = null;
    route(event, "change", ofText);
  }, true);
}

// ---- requests ---------------------------------------------------------------------------

// Identifies a control among the others of a component that raise the same event.
var controlIds = new WeakMap();
var controlCount = 0;

function controlKey(element) {
  if (!controlIds.has(element)) controlIds.set(element, element.getAttribute("name") || element.id || "#" + (++controlCount));
  return controlIds.get(element);
}

function rootOf(target) {
  var root = target.closest("[data-spark-root]") || target;
  return root.getAttribute("data-spark-id");
}

// Turns a user action into an event and delivers it. *how*: `coalesce` (the event carries a whole
// value, so a newer one replaces an older one that waits), `dom` (the DOM event kind, part of the
// key), `once` (at-most-once delivery).
function push(element, event, payload, loading, how) {
  var undo = loading ? loading() : null;
  var target = element.closest("[data-spark-id]");
  if (!target) return;
  var targetName = element.getAttribute("spark-target");
  if (targetName === "parent") {
    target = (target.parentElement && target.parentElement.closest("[data-spark-id]")) || target;
  } else if (targetName === "root") {
    target = target.closest("[data-spark-root]") || (function (el) {
      while (el.parentElement && el.parentElement.closest("[data-spark-id]")) el = el.parentElement.closest("[data-spark-id]");
      return el;
    })(target);
  } else if (targetName) {
    var selected = document.querySelector(targetName);
    target = (selected && selected.closest("[data-spark-id]")) || target;
  }
  how = how || {};
  var targetId = target.getAttribute("data-spark-id");
  var root = rootOf(target);
  var rootEl = target.closest("[data-spark-root]");
  var entry = {
    message: { v: PROTOCOL, type: "event", target: targetId, event: event, payload: payload },
    undo: undo, at: now(), root: root, once: !!how.once, rootEl: rootEl,
    key: how.coalesce ? targetId + "|" + event + "|" + controlKey(element) + "|" + how.dom : null
  };
  if (gens.has(root)) entry.message.gen = gens.get(root); // the page state this event was made against
  if (rootEl) startBusy(rootEl);
  if (machine.state.name === "stopped" || machine.state.name === "idle") {
    release(entry);
    return emit("offline", { event: event }, element);
  }
  var held = enqueue(entry);
  pump();
  trim();
  if (queue.indexOf(held) >= 0) emit("queued", { event: event, size: queue.length }, element);
  wake("connect"); // an event made while idle wakes the connection
}

// The connection is gone. What was sent and not acknowledged may or may not have been applied:
// it goes back to the front of the queue to be sent again with its number (the server applies a
// number once), except an at-most-once event, which is dropped.
function cancelPending() {
  var again = [];
  pending.forEach(function (entry) {
    if (entry.once) drop(entry, "disconnect"); else again.push(entry);
  });
  pending.clear();
  again.sort(function (a, b) { return a.message.eid - b.message.eid; });
  queue = again.concat(queue);
  trim();
}

// A request nobody answered stops looking busy; it stays unacknowledged.
function expirePending() {
  var current = now();
  pending.forEach(function (entry) { if (current - entry.sentAt > config.requestTimeout) release(entry); });
}

// An idle tab (or one closing to idle) connects again. *type* is "visible" when the tab is known to be shown (focus), so it stops counting as hidden.
function wake(type) {
  var state = machine.state;
  if (state.name === "hidden-idle" || state.then === "hidden-idle") machine.dispatch({ type: type });
}

function loadingStates(element) {
  var label = element.getAttribute("spark-disable-with");
  var klass = element.getAttribute("spark-optimistic-class");
  if (!label && !klass) return null;
  return function () {
    var isInput = element.nodeName === "INPUT";
    var original = isInput ? element.value : element.textContent;
    if (label) { if (isInput) element.value = label; else element.textContent = label; element.disabled = true; }
    if (klass) element.classList.add.apply(element.classList, klass.split(/\s+/).filter(Boolean));
    return function () {
      if (label) { if (isInput) element.value = original; else element.textContent = original; element.disabled = false; }
      if (klass) element.classList.remove.apply(element.classList, klass.split(/\s+/).filter(Boolean));
    };
  };
}

function valuesOf(element) {
  var payload = {};
  Array.prototype.forEach.call(element.attributes, function (attr) {
    if (attr.name.indexOf("spark-value-") === 0) payload[attr.name.slice(12).replace(/-/g, "_")] = attr.value;
  });
  return payload;
}

function controlPayload(control) {
  var payload = {};
  var value;
  if (control.type === "checkbox") value = control.checked;
  else if (control.type === "file") return payload;
  else if (control.nodeName === "SELECT" && control.multiple) {
    value = Array.prototype.filter.call(control.options, function (o) { return o.selected; }).map(function (o) { return o.value; });
  } else value = control.value;
  payload.value = value;
  if (control.name) payload[control.name] = value;
  return payload;
}

function formPayload(form) {
  var payload = {};
  new FormData(form).forEach(function (value, key) {
    if (typeof value !== "string") return;
    if (Object.prototype.hasOwnProperty.call(payload, key)) {
      payload[key] = [].concat(payload[key], value);
    } else payload[key] = value;
  });
  return payload;
}

function assign(target, source) {
  Object.keys(source).forEach(function (key) { target[key] = source[key]; });
  return target;
}

var debounced = new Set(); // sends waiting for the pause to end: {element, timer, work}

// Sends the debounced events of *within* (an element or a container; all when omitted) now, so the
// last keystroke is not lost to a blur, a submit or a closing page, and keeps its place in line.
function flushDebounced(within) {
  debounced.forEach(function (slot) {
    if (within && !within.contains(slot.element) && !slot.element.contains(within)) return;
    clearTimeout(slot.timer);
    debounced.delete(slot);
    slot.work();
  });
}

function throttled(element, kind, name, ms, work, mode) {
  var state = timers.get(element) || {};
  timers.set(element, state);
  var key = kind + ":" + name;
  if (mode === "debounce") {
    if (state[key]) {
      clearTimeout(state[key].timer);
      debounced.delete(state[key]);
    }
    var slot = state[key] = { element: element, work: work };
    slot.timer = setTimeout(function () { debounced.delete(slot); work(); }, ms);
    debounced.add(slot);
  } else {
    var now = Date.now();
    if (state[key] && now - state[key] < ms) return;
    state[key] = now;
    work();
  }
}

function dispatch(kind, domEvent, element) {
  var name = element.getAttribute("spark-" + kind);
  var key = element.getAttribute("spark-key");
  if (key && domEvent.key !== key) return;
  var confirmText = element.getAttribute("spark-confirm");
  // Only the events that can be cancelled and are not passive: a keyup (or input) cannot be.
  if (kind === "submit" || kind === "click" || (key && domEvent.type === "keydown")) domEvent.preventDefault();
  var how = {
    coalesce: kind === "change" && textual(element),
    dom: domEvent.type === "compositionend" ? "input" : domEvent.type,
    once: element.getAttribute("spark-delivery") === "at-most-once"
  };
  var send = function () {
    if (confirmText && !window.confirm(confirmText)) return;
    var payload = valuesOf(element);
    if (element.nodeName === "FORM") assign(payload, formPayload(element));
    else if (/^(INPUT|SELECT|TEXTAREA)$/.test(element.nodeName) && kind !== "click") assign(payload, controlPayload(element));
    push(element, name, payload, loadingStates(element), how);
  };
  var debounce = parseInt(element.getAttribute("spark-debounce"), 10);
  var throttle = parseInt(element.getAttribute("spark-throttle"), 10);
  if (debounce > 0) throttled(element, kind, name, debounce, send, "debounce");
  else if (throttle > 0) throttled(element, kind, name, throttle, send, "throttle");
  else send();
}

// One handler for a DOM event, from any of the listeners below: finds the element that asked for
// it (`spark-<kind>`) and sends. Nothing is sent while an IME composes: the text is not final, and
// the key that confirms it is not a key press. `compositionend` sends the final text instead.
function route(event, kind, accepts) {
  var start = event.target;
  if (!(start instanceof Element)) return;
  if (event.type === "blur" || event.type === "submit") flushDebounced(start);
  if (event.isComposing || event.keyCode === 229) return;
  var element = start.closest("[spark-" + kind + "]");
  if (!element || !element.closest("[data-spark-id]")) return;
  if (accepts && !accepts(event, element)) return;
  dispatch(kind, event, element);
}

// One listener per event type, on the document: elements come and go with every patch. Those that
// never cancel the event are passive, so the browser does not wait for them.
function listen(domEvent, kind, capture, passive, accepts) {
  document.addEventListener(domEvent, function (event) { route(event, kind, accepts); }, { capture: capture, passive: passive });
}

function textual(control) {
  return control.nodeName === "TEXTAREA" || (control.nodeName === "INPUT" && !/^(checkbox|radio|file|range|color|button|submit)$/.test(control.type));
}

function ofText(event) { return textual(event.target); }

function bind() {
  listen("click", "click", false, false);
  listen("submit", "submit", false, false);
  listen("keydown", "keydown", false, false);
  listen("keyup", "keyup", false, true);
  listen("blur", "blur", true, true);
  listen("focus", "focus", true, true);
  // Text controls report every keystroke (`input`); everything else reports on `change`.
  listen("input", "change", false, true, ofText);
  listen("change", "change", false, true, function (event) { return !textual(event.target); });
}

// ---- page changes -----------------------------------------------------------------------

function observe() {
  new MutationObserver(function (records) {
    records.forEach(function (record) {
      Array.prototype.forEach.call(record.addedNodes, function (node) {
        if (node.nodeType === 1 && (node.hasAttribute("data-spark-root") || node.querySelector("[data-spark-root]"))) joinRoots(node.parentNode || document);
      });
      Array.prototype.forEach.call(record.removedNodes, function (node) {
        if (node.nodeType !== 1) return;
        var removed = node.hasAttribute("data-spark-root") ? [node] : roots(node);
        removed.forEach(function (root) {
          var id = root.getAttribute("data-spark-id");
          if (!joined.delete(id)) return;
          snapshots.delete(id);
          gens.delete(id);
          transmit({ v: PROTOCOL, type: "leave", target: id });
        });
      });
    });
  }).observe(document.body, { childList: true, subtree: true });
}

function stop() {
  var forgotten = queue.splice(0);
  pending.forEach(function (entry) { forgotten.push(entry); });
  pending.clear();
  forgotten.forEach(function (entry) { drop(entry, "stopped"); });
  machine.dispatch({ type: "stop" });
}

function start() {
  if (booted) return;
  booted = true;
  bind();
  observe();
  watchUser();
  window.addEventListener("online", function () { machine.dispatch({ type: "online" }); });
  window.addEventListener("offline", function () { machine.dispatch({ type: "offline" }); });
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState !== "visible") flushDebounced();
    machine.dispatch({ type: document.visibilityState === "visible" ? "visible" : "hidden" });
  });
  window.addEventListener("focus", function () { wake("visible"); }); // also wakes an idle tab whose visibilitychange was missed
  if (document.visibilityState === "hidden") machine.dispatch({ type: "hidden" });
  window.addEventListener("pageshow", function (event) { if (event.persisted) machine.dispatch({ type: "pageshow" }); });
  window.addEventListener("pagehide", function () {
    flushDebounced();
    machine.dispatch({ type: "pagehide" });
  });
  if (roots().length > 0) machine.dispatch({ type: "connect" });
  else document.addEventListener("DOMContentLoaded", function () { if (roots().length > 0) machine.dispatch({ type: "connect" }); });
}

window.AzuSpark = {
  get status() { return status; },
  get queued() { return queue.length; },
  get unacked() { return pending.size; },
  connect: function () { machine.dispatch({ type: "connect" }); },
  disconnect: stop,
  stats: snapshot,
  configure: function (options) {
    if (options.hiddenIdle !== undefined) config.idleMs = Math.max(0, +options.hiddenIdle || 0);
    if (options.live !== undefined) config.live = !!options.live;
    if (options.debug !== undefined) debug = !!options.debug;
    if (options.text) text = Object.assign({}, options.text);
    return this;
  },
  on: function (name, fn) { (handlers[name] = handlers[name] || []).push(fn); return this; },
  off: function (name, fn) { handlers[name] = (handlers[name] || []).filter(function (h) { return h !== fn; }); return this; },
  push: function (element, event, payload) { push(element, event, payload || {}); }
};
if (!window.Spark) window.Spark = window.AzuSpark;

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
else start();

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
 * @typedef {{ message: Record<string, unknown>, undo?: (() => void) | null, key?: string | null, at: number }} QueuedEvent
 * @typedef {{ v: number, type: string, id?: number, [field: string]: unknown }} SparkMessage
 */

var PROTOCOL = 1;
var script = document.currentScript;
var config = {
  path: (script && script.getAttribute("data-spark-path")) || "/spark",
  backoffMin: 500,
  backoffMax: 15000,
  requestTimeout: 10000,
  probeTimeout: 3000,
  stableAfter: 10000, // a connection must stay open this long before the backoff starts over
  queueMax: 50,
  queueMaxAge: 60000
};

var ws = null;
var status = "disconnected";
var hello = null;
var nextId = 0;
var booted = false;
var pending = new Map(); // request id -> {undo, sentAt}
var queue = []; // events waiting for a connection: {message, undo, key, at}
var joining = new Map(); // join request id -> root id
var handlers = {}; // Spark.on(...)
var joined = new Set(); // root ids joined on the current socket
var snapshots = new Map(); // root id -> signed state snapshot
var timers = new WeakMap(); // element -> {kind: timer or time}

// ---- helpers --------------------------------------------------------------------------

function emit(name, detail, target) {
  (target || document).dispatchEvent(new CustomEvent("spark:" + name, { bubbles: true, detail: detail }));
  (handlers[name] || []).slice().forEach(function (fn) {
    try { fn(detail); } catch (e) { if (window.console) console.error(e); }
  });
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

// Sends *entry* (a queued or fresh event) now; false when there is no open socket.
function send(entry) {
  // Not before the server greeted us and every page root has rejoined: earlier, the target does not exist yet.
  if (machine.state.name !== "open") return false;
  var id = ++nextId;
  entry.message.id = id;
  if (transmit(entry.message)) pending.set(id, { undo: entry.undo, sentAt: now() });
  else release(entry); // too large for the server: reported as an error, never retried
  return true;
}

function release(entry) {
  if (entry.undo) entry.undo();
}

// Events wait here while there is no connection: bounded (the oldest is dropped), and an event
// that carries a whole value (a text input) replaces the older one for the same target.
function enqueue(entry) {
  if (entry.key) {
    queue = queue.filter(function (queued) {
      if (queued.key !== entry.key) return true;
      release(queued);
      return false;
    });
  }
  queue.push(entry);
  while (queue.length > config.queueMax) {
    release(queue.shift());
    emit("error", { code: "queue_full", message: "too many events while offline" });
  }
}

function joinsSettled() {
  if (joining.size > 0) return;
  machine.dispatch({ type: "joins_settled" });
  flushQueue();
}

function flushQueue() {
  var waiting = queue;
  queue = [];
  var current = now();
  waiting.forEach(function (entry) {
    if (current - entry.at > config.queueMaxAge) release(entry);
    else if (!send(entry)) queue.push(entry);
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
//   hidden-idle  closed on purpose while the tab is hidden (reserved: nothing enters it yet)
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
  pagehide: function (state) { return closeThen(state, "idle", 1000, "page closed"); }
};

var BEATING = [{ type: "heartbeat" }];
var JOIN_WATCH = after("join", TIMING.join, { type: "dead", reason: "join timeout" });

function probe(state) { return go(state, [{ type: "probe" }]); }
function forget(state) { return go(st(state.name, 0)); } // the backoff starts over: the connection proved stable

function withSocket(own) {
  return Object.assign({}, WITH_SOCKET, own);
}

function afterClose(state, event) {
  var teardown = { type: "teardown", code: event.code, reason: event.reason };
  if (state.then === "connecting") return go(st("connecting", 0), [teardown].concat(connectNow(0).effects));
  return go(st(state.then, state.attempts), [teardown]);
}

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
    online: probe, // after a sleep or a network change the socket may be dead without anyone telling us
    hide_idle: function (state) { return closeThen(state, "hidden-idle", 1000, "hidden"); }
  }),
  closing: {
    closed: afterClose,
    dead: afterClose,
    stop: function (state) { return go(st("closing", state.attempts, "stopped")); },
    pagehide: function (state) { return go(st("closing", state.attempts, state.then === "stopped" ? "stopped" : "idle")); },
    connect: function (state) { return go(st("closing", state.attempts, "connecting")); },
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
  offline: { online: networkBack, connect: retry, visible: resume, stop: stopped, pagehide: paused },
  "hidden-idle": { visible: connectFresh, connect: connectFresh, stop: stopped, pagehide: paused },
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
 *   and the host effects open, close, teardown, opened, backingOff
 * @param {object} [settings] backoffMin, backoffMax, probeTimeout, stableAfter (ms)
 */
export function createMachine(deps, settings) {
  var cfg = Object.assign({}, config, settings);
  var state = st("idle", 0);
  var timers = {};
  var inbox = [];
  var running = false;
  var lastFrameAt = 0;
  var lastWatchAt = 0;
  var lastWallAt = 0;
  var connectedAt = 0;

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
    var result = next(state, typed);
    var previous = state;
    state = result.state;
    if (state.name !== previous.name) {
      cancelAll();
      if (previous.name === "connecting" && state.name === "joining") connectedAt = deps.now();
      deps.status(statusOf(state), state);
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
  beat: function () { return transmit({ v: PROTOCOL, type: "heartbeat", id: ++nextId }); },
  tick: expirePending,
  status: setStatus,
  open: openSocket,
  close: closeSocket,
  teardown: teardown,
  opened: function () { emit("open", { attempts: machine.state.attempts }); },
  backingOff: function (delay, attempts) {
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
    case "reply": joining.delete(message.id); afterPatches(function () { settle(message.id); }); joinsSettled(); break;
    case "redirect": navigate(message.to, message.replace); break;
    case "heartbeat": break;
    case "error": failed(message); break;
  }
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
        if (element) emit(push.name, push.payload, element);
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
  settle(message.id);
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
var composing = null; // the element an IME is composing in
var touched = new WeakSet(); // <details>/<dialog> the user opened or closed
var served = new WeakMap(); // <details>/<dialog> -> the `open` the server sent last

function later(job) {
  frame.push(job);
  if (frame.length > 1) return;
  window.requestAnimationFrame(flushPatches);
  setTimeout(flushPatches, 50); // a hidden tab gets no animation frames
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
  var jobs = frame;
  frame = [];
  if (jobs.length === 0) return;
  var kept = remember(jobs.map(function (job) { return job.id === undefined ? null : byId(job.id); }).filter(Boolean));
  jobs.forEach(function (job) {
    try { job.run(); } catch (e) { emit("error", { code: "patch_failed", message: String(e && e.message || e) }); }
  });
  recall(kept);
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
  sanitize(fragment, element.closest("[data-spark-allow-scripts]") !== null);
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
    try { policy = types ? types.createPolicy("azu-spark", { createHTML: function (value) { return value; } }) : null; } catch (e) { /* the page's CSP does not list azu-spark */ }
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
      if (name.indexOf("on") === 0 || name === "srcdoc" ||
          (URL_ATTRIBUTES.indexOf(name) >= 0 && scriptUrl(attr.value, name))) node.removeAttribute(attr.name);
    });
  });
}

function keyOf(node) {
  if (node.nodeType !== 1) return null;
  var key = node.getAttribute("data-spark-id") || node.getAttribute("data-spark-key") || node.id;
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
  var matches = wanted.map(function (want) {
    var key = keyOf(want);
    var node = null;
    if (key !== null) {
      node = keyed.get(key) || null;
      keyed.delete(key);
      if (want.hasAttribute("data-spark-slot") && live.has(want.getAttribute("data-spark-id"))) node = live.get(want.getAttribute("data-spark-id"));
    } else if (loose[next] && loose[next].nodeType === want.nodeType && loose[next].nodeName === want.nodeName) {
      node = loose[next++];
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
    if (was === now || (openable && name === "open")) return;
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
  document.addEventListener("compositionstart", function (event) { composing = event.target; }, true);
  document.addEventListener("compositionend", function () { composing = null; }, true);
}

// ---- requests ---------------------------------------------------------------------------

// Identifies a control among the others of a component that raise the same event.
var controlIds = new WeakMap();
var controlCount = 0;

function controlKey(element) {
  if (!controlIds.has(element)) controlIds.set(element, element.getAttribute("name") || element.id || "#" + (++controlCount));
  return controlIds.get(element);
}

function push(element, event, payload, loading, coalesce) {
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
  var targetId = target.getAttribute("data-spark-id");
  var entry = {
    message: { v: PROTOCOL, type: "event", target: targetId, event: event, payload: payload },
    undo: undo, key: coalesce ? targetId + "|" + event + "|" + controlKey(element) : null, at: now()
  };
  if (send(entry)) return;
  if (machine.state.name === "stopped" || machine.state.name === "idle") {
    release(entry);
    return emit("offline", { event: event }, element);
  }
  enqueue(entry);
  emit("queued", { event: event, size: queue.length }, element);
}

function settle(id) {
  var entry = pending.get(id);
  if (!entry) return;
  pending.delete(id);
  if (entry.undo) entry.undo();
}

function cancelPending() {
  pending.forEach(function (entry) { if (entry.undo) entry.undo(); });
  pending.clear();
}

function expirePending() {
  var current = now();
  pending.forEach(function (entry, id) { if (current - entry.sentAt > config.requestTimeout) settle(id); });
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

function throttled(element, kind, name, ms, work, mode) {
  var state = timers.get(element) || {};
  timers.set(element, state);
  var key = kind + ":" + name;
  if (mode === "debounce") {
    clearTimeout(state[key]);
    state[key] = setTimeout(work, ms);
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
  if (kind === "submit" || kind === "click" || key) domEvent.preventDefault();
  var send = function () {
    if (confirmText && !window.confirm(confirmText)) return;
    var payload = valuesOf(element);
    if (element.nodeName === "FORM") assign(payload, formPayload(element));
    else if (/^(INPUT|SELECT|TEXTAREA)$/.test(element.nodeName) && kind !== "click") assign(payload, controlPayload(element));
    push(element, name, payload, loadingStates(element), kind === "change");
  };
  var debounce = parseInt(element.getAttribute("spark-debounce"), 10);
  var throttle = parseInt(element.getAttribute("spark-throttle"), 10);
  if (debounce > 0) throttled(element, kind, name, debounce, send, "debounce");
  else if (throttle > 0) throttled(element, kind, name, throttle, send, "throttle");
  else send();
}

function listen(domEvent, kind, capture, accepts) {
  document.addEventListener(domEvent, function (event) {
    var start = event.target;
    if (!(start instanceof Element)) return;
    var element = start.closest("[spark-" + kind + "]");
    if (!element || !element.closest("[data-spark-id]")) return;
    if (accepts && !accepts(event, element)) return;
    dispatch(kind, event, element);
  }, capture);
}

function textual(control) {
  return control.nodeName === "TEXTAREA" || (control.nodeName === "INPUT" && !/^(checkbox|radio|file|range|color|button|submit)$/.test(control.type));
}

function bind() {
  listen("click", "click", false);
  listen("submit", "submit", false);
  listen("keydown", "keydown", false);
  listen("keyup", "keyup", false);
  listen("blur", "blur", true);
  listen("focus", "focus", true);
  // Text controls report every keystroke (`input`); everything else reports on `change`.
  listen("input", "change", false, function (event) { return textual(event.target); });
  listen("change", "change", false, function (event) { return !textual(event.target); });
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
          transmit({ v: PROTOCOL, type: "leave", target: id });
        });
      });
    });
  }).observe(document.body, { childList: true, subtree: true });
}

function stop() {
  queue.splice(0).forEach(release);
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
    machine.dispatch({ type: document.visibilityState === "visible" ? "visible" : "hidden" });
  });
  window.addEventListener("pageshow", function (event) { if (event.persisted) machine.dispatch({ type: "pageshow" }); });
  window.addEventListener("pagehide", function () { machine.dispatch({ type: "pagehide" }); });
  if (roots().length > 0) machine.dispatch({ type: "connect" });
  else document.addEventListener("DOMContentLoaded", function () { if (roots().length > 0) machine.dispatch({ type: "connect" }); });
}

window.AzuSpark = {
  get status() { return status; },
  get queued() { return queue.length; },
  connect: function () { machine.dispatch({ type: "connect" }); },
  disconnect: stop,
  on: function (name, fn) { (handlers[name] = handlers[name] || []).push(fn); return this; },
  off: function (name, fn) { handlers[name] = (handlers[name] || []).filter(function (h) { return h !== fn; }); return this; },
  push: function (element, event, payload) { push(element, event, payload || {}); }
};
if (!window.Spark) window.Spark = window.AzuSpark;

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
else start();

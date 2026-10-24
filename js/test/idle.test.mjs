// Hidden tab idle: the socket is closed on purpose after IDLE_MS hidden and rejoined from the latest
// snapshot when the tab returns. Machine level on a fake clock; host level against a fake WebSocket.
import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { FakeSocket, connected, harness, loadSpark, open, tick, until } from "./helpers.mjs";

let spark;
const IDLE = 300000;
beforeEach(async () => { spark = await loadSpark(); });

// Time passes with a server that keeps answering (a silent connection would be dropped by the watchdog).
function pass(h, ms) {
  for (let left = ms; left > 0; left -= 1000) {
    h.clock.advance(Math.min(1000, left));
    h.machine.frame();
  }
}

const closes = (h) => h.log.filter((entry) => entry.name === "close");

describe("hidden idle (machine)", () => {
  it("closes cleanly with 1000 after the tab has been hidden for the whole window, then waits in hidden-idle", () => {
    const h = harness(spark, { settings: { idleMs: IDLE } });
    open(h);
    h.machine.dispatch({ type: "hidden" });
    pass(h, IDLE - 1);
    assert.equal(h.machine.state.name, "open");
    assert.equal(closes(h).length, 0);
    h.clock.advance(1);
    assert.equal(h.machine.state.name, "closing");
    assert.deepEqual(closes(h).map((c) => [c.code, c.reason]), [[1000, "hidden idle"]]);
    h.machine.dispatch({ type: "closed", code: 1000, reason: "hidden idle" });
    assert.equal(h.machine.state.name, "hidden-idle");
    assert.equal(h.machine.timers(), 0, "nothing runs while idle");
    assert.equal(h.clock.pending(), 0);
    assert.equal(h.log.filter((e) => e.name === "backingOff").length, 0, "an idle close is not a lost connection: no backoff");
  });

  it("a tab that becomes visible in time keeps its connection, and the window starts over when it hides again", () => {
    const h = harness(spark, { settings: { idleMs: IDLE } });
    open(h);
    h.machine.dispatch({ type: "hidden" });
    pass(h, IDLE - 10);
    h.machine.dispatch({ type: "visible" });
    pass(h, IDLE * 2);
    assert.equal(h.machine.state.name, "open");
    h.machine.dispatch({ type: "hidden" });
    pass(h, IDLE - 1);
    assert.equal(h.machine.state.name, "open");
    h.clock.advance(1);
    assert.equal(h.machine.state.name, "closing");
  });

  it("a hidden tab that is healthy inside the window keeps heartbeating and nothing flaps", () => {
    const h = harness(spark, { settings: { idleMs: IDLE } });
    open(h);
    h.machine.dispatch({ type: "hidden" });
    const before = h.log.length;
    for (let second = 0; second < 60; second++) {
      h.clock.advance(1000);
      h.machine.frame(); // the server keeps answering
    }
    assert.equal(h.machine.state.name, "open");
    assert.ok(h.status.beats >= 59, `heartbeats continued: ${h.status.beats}`);
    assert.equal(h.log.length, before, "no transition, no close, no status change");
  });

  it("can be turned off", () => {
    const h = harness(spark, { settings: { idleMs: 0 } });
    open(h);
    h.machine.dispatch({ type: "hidden" });
    pass(h, IDLE * 10);
    assert.equal(h.machine.state.name, "open");
  });

  it("returns to a connection when the tab is visible again", () => {
    const h = harness(spark, { settings: { idleMs: IDLE } });
    open(h);
    h.machine.dispatch({ type: "hidden" });
    pass(h, IDLE);
    h.machine.dispatch({ type: "closed", code: 1000 });
    h.machine.dispatch({ type: "visible" });
    assert.equal(h.machine.state.name, "connecting");
    assert.equal(h.machine.state.attempts, 0);
    assert.equal(h.log.filter((e) => e.name === "open").length, 2);
    assert.equal(h.machine.timers(), 1, "the connect watch");
  });

  it("an idle close during backoff does not forget the attempts: a server that is down keeps getting longer delays", () => {
    const h = harness(spark, { settings: { idleMs: IDLE } });
    open(h);
    h.machine.dispatch({ type: "closed", code: 1006 });
    h.machine.dispatch({ type: "hidden" });
    pass(h, IDLE);
    h.machine.dispatch({ type: "closed", code: 1000 });
    assert.equal(h.machine.state.name, "hidden-idle");
    const attempts = h.machine.state.attempts;
    assert.ok(attempts >= 1);
    h.machine.dispatch({ type: "visible" });
    assert.equal(h.machine.state.name, "connecting");
    assert.equal(h.machine.state.attempts, attempts);
  });

  it("a tab that returns while the idle close is still pending reconnects once it has finished", () => {
    const h = harness(spark, { settings: { idleMs: IDLE } });
    open(h);
    h.machine.dispatch({ type: "hidden" });
    pass(h, IDLE);
    assert.equal(h.machine.state.name, "closing");
    h.machine.dispatch({ type: "visible" });
    h.machine.dispatch({ type: "closed", code: 1000 });
    assert.equal(h.machine.state.name, "connecting");
  });

  it("a tab that is hidden when the connection starts idles from then on", () => {
    const h = harness(spark, { settings: { idleMs: IDLE } });
    h.machine.dispatch({ type: "hidden" });
    h.machine.dispatch({ type: "connect" });
    h.machine.frame();
    h.machine.dispatch({ type: "hello" });
    h.machine.dispatch({ type: "joins_settled" });
    pass(h, IDLE);
    assert.equal(h.machine.state.name, "closing");
  });

  it("a hidden tab woken by an event idles again", () => {
    const h = harness(spark, { settings: { idleMs: IDLE } });
    open(h);
    h.machine.dispatch({ type: "hidden" });
    pass(h, IDLE);
    h.machine.dispatch({ type: "closed", code: 1000 });
    h.machine.dispatch({ type: "connect" }); // an event was made while hidden
    h.machine.frame();
    h.machine.dispatch({ type: "hello" });
    h.machine.dispatch({ type: "joins_settled" });
    assert.equal(h.machine.state.name, "open");
    pass(h, IDLE);
    assert.equal(h.machine.state.name, "closing");
  });

  it("a page that is leaving or stopped never idles", () => {
    for (const leave of ["stop", "pagehide"]) {
      const h = harness(spark, { settings: { idleMs: IDLE } });
      open(h);
      h.machine.dispatch({ type: "hidden" });
      h.machine.dispatch({ type: leave });
      h.machine.dispatch({ type: "closed", code: 1000 });
      pass(h, IDLE * 2);
      assert.notEqual(h.machine.state.name, "hidden-idle", leave);
      assert.equal(closes(h).length, 1, `${leave}: only its own close`);
    }
  });

  it("reports every state change with where it came from and why", () => {
    const changes = [];
    const h = harness(spark, { settings: { idleMs: IDLE }, changed: (from, to, event) => changes.push([from.name, to.name, event.type]) });
    open(h);
    h.machine.dispatch({ type: "hidden" });
    pass(h, IDLE);
    h.machine.dispatch({ type: "closed", code: 1000 });
    assert.deepEqual(changes.slice(-2), [["open", "closing", "hide_idle"], ["closing", "hidden-idle", "closed"]]);
  });
});

// ---- host level ---------------------------------------------------------------------

const ROOT = `<div data-spark-root data-spark-id="r" data-spark-token="t">
  <input id="a" name="a" spark-change="set"><button id="go" spark-click="go">go</button></div>`;
const $ = (id) => document.getElementById(id);
const click = (id) => $(id).dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
const visibility = (state) => {
  Object.defineProperty(document, "visibilityState", { value: state, configurable: true });
  document.dispatchEvent(new window.Event("visibilitychange"));
};

describe("hidden idle (client)", () => {
  beforeEach(async () => {
    document.body.innerHTML = ROOT;
    window.AzuSpark.configure({ hiddenIdle: 40 });
    await tick();
  });
  afterEach(async () => {
    visibility("visible");
    window.AzuSpark.configure({ hiddenIdle: 300000 });
    window.AzuSpark.disconnect();
    await tick(5);
  });

  it("closes the socket with 1000 after the window, rejoins from the snapshot, and resends in order what was unanswered", async () => {
    const first = await connected();
    first.receive({ type: "diff", seq: 1, patches: [], events: [], snapshots: { r: "snap-1" } });
    click("go"); click("go");
    assert.equal(first.events.length, 2);
    let code;
    first.close = function (c, reason) { code = [c, reason]; FakeSocket.prototype.close.call(this, c, reason); };
    visibility("hidden");
    await until(() => code, "the idle close");
    assert.deepEqual(code, [1000, "hidden idle"]);
    await until(() => window.AzuSpark.stats().state === "hidden-idle", "hidden-idle");
    assert.equal(window.AzuSpark.stats().queue.waiting, 2, "the unanswered events wait for the return");
    assert.equal(FakeSocket.all.filter((s) => s.readyState !== FakeSocket.CLOSED).length, 0, "no socket while hidden");

    const before = FakeSocket.all.length;
    visibility("visible");
    const second = await connected({ before });
    assert.equal(second.of("join")[0].snapshot, "snap-1", "rejoined from the latest snapshot");
    assert.deepEqual(second.events.map((e) => e.eid), first.events.map((e) => e.eid), "same events, same numbers, same order");
    assert.equal(window.AzuSpark.queued, 0);
  });

  it("an event made while the tab sits idle wakes the connection and is delivered", async () => {
    const first = await connected();
    visibility("hidden");
    await until(() => window.AzuSpark.stats().state === "hidden-idle", "hidden-idle");
    const before = FakeSocket.all.length;
    click("go");
    assert.equal(window.AzuSpark.queued, 1);
    const second = await connected({ before });
    assert.equal(second.events.length, 1);
    assert.equal(first.events.length, 0);
  });

  it("a visible tab never idles", async () => {
    await connected();
    await tick(120);
    assert.equal(window.AzuSpark.stats().state, "open");
  });
});

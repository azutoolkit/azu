// Observability: AzuSpark.on events, stats(), zero overhead without listeners, redacted debug tracing.
import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { FakeSocket, connected, loadSpark, tick, until } from "./helpers.mjs";

const ROOT = `<div data-spark-root data-spark-id="r" data-spark-token="TOKEN-SECRET">
  <div data-spark-id="r~c"><p>x</p></div>
  <input id="a" name="a" spark-change="set"><button id="go" spark-click="go">go</button></div>`;
const $ = (id) => document.getElementById(id);
const click = (id) => $(id).dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
const listeners = [];
const on = (name, fn) => { window.AzuSpark.on(name, fn); listeners.push([name, fn]); return fn; };
const TELEMETRY = /^spark:(state|rtt|timing|delivery)$/;
let created;

beforeEach(async () => {
  await loadSpark();
  document.body.innerHTML = ROOT;
  created = [];
  const Native = window.CustomEvent;
  globalThis.CustomEvent = class extends Native {
    constructor(type, init) { super(type, init); created.push(type); }
  };
  await tick();
});

afterEach(async () => {
  while (listeners.length) window.AzuSpark.off(...listeners.pop());
  window.AzuSpark.configure({ debug: false });
  window.AzuSpark.disconnect();
  await tick(5);
  globalThis.CustomEvent = window.CustomEvent;
});

describe("events", () => {
  it("state: every change with from, to, reason and attempts", async () => {
    const seen = [];
    on("state", (d) => seen.push(d));
    const socket = await connected();
    assert.deepEqual(seen.map((d) => `${d.from}>${d.to}`), ["idle>connecting", "connecting>joining", "joining>open"]);
    assert.deepEqual(seen[1], { from: "connecting", to: "joining", reason: "hello", attempts: 0 });
    socket.drop();
    assert.deepEqual(seen.at(-1), { from: "open", to: "backoff", reason: "closed", attempts: 1 });
  });

  it("reconnect: attempt and delay", async () => {
    const seen = [];
    on("reconnect", (d) => seen.push(d));
    (await connected()).drop();
    assert.equal(seen.length, 1);
    assert.equal(seen[0].attempts, 1);
    assert.ok(seen[0].delay >= 0 && seen[0].delay <= 500);
  });

  it("rtt: the heartbeat answer gives the round trip, with a median", async () => {
    const rtts = [];
    on("rtt", (d) => rtts.push(d));
    const socket = await connected();
    document.dispatchEvent(new window.Event("visibilitychange")); // a tab that shows again asks for a sign of life
    const beat = socket.of("heartbeat").at(-1);
    await tick(5);
    socket.receive({ type: "heartbeat", id: beat.id });
    assert.equal(rtts.length, 1);
    assert.ok(rtts[0].ms >= 4 && rtts[0].ms < 1000, String(rtts[0].ms));
    assert.equal(typeof rtts[0].p50, "number");
    assert.equal(window.AzuSpark.stats().rtt.last, rtts[0].ms);
  });

  it("timing: one event per patch flush with the number of patches and the time", async () => {
    const timings = [];
    on("timing", (d) => timings.push(d));
    const socket = await connected();
    socket.receive({ type: "diff", seq: 1, patches: [{ id: "r~c", html: "<p>1</p>" }, { id: "r~c", html: "<p>2</p>" }], events: [], snapshots: {} });
    await until(() => timings.length, "a flush");
    assert.equal(timings[0].patches, 2);
    assert.ok(timings[0].ms >= 0);
    assert.ok(window.AzuSpark.stats().patches.applied >= 2);
  });

  it("delivery: sent, acked, resent and dropped, with the event name and number", async () => {
    const phases = [];
    on("delivery", (d) => phases.push(`${d.phase}:${d.event}:${d.eid}`));
    const first = await connected();
    click("go");
    first.drop();
    const second = await connected();
    const frame = second.events[0];
    second.receive({ type: "reply", id: frame.id, target: frame.target });
    await tick(80);
    assert.deepEqual(phases, ["sent:go:1", "resent:go:1", "acked:go:1"].map((p) => p.replace(":1", `:${frame.eid}`)));
  });
});

describe("stats", () => {
  it("is a snapshot of state, attempts, rtt, queues, bytes and patches", async () => {
    const before = window.AzuSpark.stats();
    assert.equal(typeof before.state, "string");
    const socket = await connected();
    click("go");
    const mid = window.AzuSpark.stats();
    assert.equal(mid.state, "open");
        assert.equal(mid.attempts, 0);
    assert.deepEqual(mid.queue, { waiting: 0, unacked: 1 });
    assert.ok(mid.bytes.out > before.bytes.out && mid.bytes.in > before.bytes.in);
    assert.equal(mid.delivery.sent, before.delivery.sent + 1);
    const frame = socket.events[0];
    socket.receive({ type: "reply", id: frame.id, target: frame.target });
    const after = window.AzuSpark.stats();
    assert.equal(after.delivery.acked, mid.delivery.acked + 1);
    assert.ok(after.bytes.in > mid.bytes.in);
    assert.notEqual(window.AzuSpark.stats(), window.AzuSpark.stats(), "a new object each time: a snapshot, not live state");
  });

  it("counts reconnects and reports the round trip once a heartbeat was answered", async () => {
    const before = window.AzuSpark.stats().reconnects;
    const socket = await connected();
    document.dispatchEvent(new window.Event("visibilitychange"));
    socket.receive({ type: "heartbeat", id: socket.of("heartbeat").at(-1).id });
    const { rtt } = window.AzuSpark.stats();
    assert.ok(rtt.last >= 0 && rtt.p50 >= 0, JSON.stringify(rtt));
    socket.drop();
    assert.equal(window.AzuSpark.stats().reconnects, before + 1);
  });
});

describe("cost without listeners", () => {
  it("creates no telemetry event objects when nobody listens", async () => {
    const socket = await connected();
    click("go");
    document.dispatchEvent(new window.Event("visibilitychange")); // a tab that shows again asks for a sign of life
    socket.receive({ type: "heartbeat", id: socket.of("heartbeat").at(-1).id });
    socket.receive({ type: "diff", seq: 1, patches: [{ id: "r~c", html: "<p>z</p>" }], events: [], snapshots: {} });
    await tick(80);
    socket.drop();
    assert.deepEqual(created.filter((type) => TELEMETRY.test(type)), []);
    assert.ok(window.AzuSpark.stats().patches.applied > 0, "the counters still count");
  });

  it("dispatches DOM events once someone listens through on(), and not for the others", async () => {
    const heard = [];
    document.addEventListener("spark:rtt", (e) => heard.push(e.detail));
    on("state", () => {});
    const socket = await connected();
    document.dispatchEvent(new window.Event("visibilitychange")); // a tab that shows again asks for a sign of life
    socket.receive({ type: "heartbeat", id: socket.of("heartbeat").at(-1).id });
    assert.deepEqual(heard, [], "rtt has no subscriber: no event");
    assert.ok(created.includes("spark:state"));
    assert.ok(!created.includes("spark:rtt"));
  });
});

describe("debug tracing", () => {
  it("is off by default and logs nothing", async () => {
    const lines = [];
    const log = console.debug;
    console.debug = (...args) => lines.push(args);
    try { (await connected()).drop(); } finally { console.debug = log; }
    assert.deepEqual(lines, []);
  });

  it("traces events with their values redacted: no payloads, tokens, snapshots or messages", async () => {
    const lines = [];
    const log = console.debug;
    console.debug = (...args) => lines.push(args);
    try {
      window.AzuSpark.configure({ debug: true });
      const socket = await connected();
      $("a").value = "PAYLOAD-SECRET";
      $("a").dispatchEvent(new window.InputEvent("input", { bubbles: true }));
      socket.receive({ type: "diff", seq: 1, patches: [{ id: "r~c", html: "<p>HTML-SECRET</p>" }], events: [{ target: "r~c", name: "notice", payload: { balance: 4242, text: "PUSH-SECRET" } }], snapshots: { r: "SNAPSHOT-SECRET" } });
      socket.receive({ type: "error", id: 99, code: "boom", message: "MESSAGE-SECRET" });
      await tick(80);
      socket.drop();
    } finally { console.debug = log; }
    const text = JSON.stringify(lines);
    for (const secret of ["PAYLOAD-SECRET", "TOKEN-SECRET", "SNAPSHOT-SECRET", "HTML-SECRET", "MESSAGE-SECRET", "PUSH-SECRET", "4242"]) {
      assert.ok(!text.includes(secret), `${secret} must not be logged`);
    }
    assert.ok(lines.length > 3, "it did trace");
    assert.ok(lines.every((args) => args[0] === "[azu-spark]"));
    assert.ok(text.includes("boom"), "codes are not secret");
    assert.ok(lines.some((args) => args[1] === "state"));
  });
});

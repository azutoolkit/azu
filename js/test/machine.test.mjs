// The connection state machine: every transition, the runner's timers, backoff, the heartbeat verdict.
import assert from "node:assert/strict";
import { before, describe, it } from "node:test";
import { harness, loadSpark, open } from "./helpers.mjs";

let spark;
before(async () => { spark = await loadSpark(); });

// [state, event, expected state, expected attempts]; every pair that is not listed must be ignored.
// Base state: attempts 2. `closing` has its own table below because it carries where it leads.
const TABLE = [
  ["idle", "connect", "connecting", 0], ["idle", "pageshow", "connecting", 0], ["idle", "stop", "stopped", 2],
  ["connecting", "hello", "joining", 2], ["connecting", "closed", "backoff", 3], ["connecting", "dead", "backoff", 3],
  ["connecting", "offline", "offline", 2], ["connecting", "stop", "closing", 2], ["connecting", "pagehide", "closing", 2],
  ["joining", "joins_settled", "open", 2], ["joining", "stable", "joining", 0], ["joining", "closed", "backoff", 3],
  ["joining", "dead", "backoff", 3], ["joining", "offline", "offline", 2], ["joining", "stop", "closing", 2],
  ["joining", "pagehide", "closing", 2], ["joining", "visible", "joining", 2],
  ["open", "joins_pending", "joining", 2], ["open", "stable", "open", 0], ["open", "visible", "open", 2],
  ["open", "hide_idle", "closing", 2], ["open", "closed", "backoff", 3], ["open", "dead", "backoff", 3],
  ["open", "offline", "offline", 2], ["open", "stop", "closing", 2], ["open", "pagehide", "closing", 2],
  ["backoff", "backoff_elapsed", "connecting", 2], ["backoff", "connect", "connecting", 2], ["backoff", "visible", "connecting", 2],
  ["backoff", "online", "connecting", 0], ["backoff", "offline", "offline", 2], ["backoff", "hide_idle", "hidden-idle", 2],
  ["backoff", "stop", "stopped", 2], ["backoff", "pagehide", "idle", 2],
  ["offline", "online", "connecting", 0], ["offline", "connect", "connecting", 2], ["offline", "visible", "connecting", 2],
  ["offline", "stop", "stopped", 2], ["offline", "pagehide", "idle", 2],
  ["hidden-idle", "visible", "connecting", 0], ["hidden-idle", "connect", "connecting", 0],
  ["hidden-idle", "stop", "stopped", 2], ["hidden-idle", "pagehide", "idle", 2],
  ["stopped", "connect", "connecting", 0],
];

const CLOSING = [
  // [then, event, expected state, expected then]
  ["stopped", "closed", "stopped"], ["stopped", "dead", "stopped"], ["stopped", "stop", "closing", "stopped"],
  ["stopped", "pagehide", "closing", "stopped"], ["stopped", "connect", "closing", "connecting"],
  ["idle", "closed", "idle"], ["idle", "stop", "closing", "stopped"], ["idle", "pagehide", "closing", "idle"], ["idle", "connect", "closing", "connecting"],
  ["hidden-idle", "closed", "hidden-idle"], ["hidden-idle", "pagehide", "closing", "idle"],
  ["connecting", "closed", "connecting"], ["connecting", "stop", "closing", "stopped"],
];

describe("transitions", () => {
  it("lists every state and event", () => {
    assert.deepEqual(Object.keys(spark.TRANSITIONS).sort(), [...spark.STATES].sort());
    for (const row of Object.values(spark.TRANSITIONS)) for (const event of Object.keys(row)) assert.ok(spark.EVENTS.includes(event), event);
  });

  for (const [from, event, to, attempts] of TABLE) {
    it(`${from} + ${event} -> ${to}`, () => {
      const result = spark.next({ name: from, attempts: 2 }, { type: event, online: true });
      assert.equal(result.state.name, to);
      assert.equal(result.state.attempts, attempts);
    });
  }

  for (const [then, event, to, andThen] of CLOSING) {
    it(`closing(${then}) + ${event} -> ${to}${andThen ? `(${andThen})` : ""}`, () => {
      const result = spark.next({ name: "closing", attempts: 2, then }, { type: event, online: true });
      assert.equal(result.state.name, to);
      assert.equal(result.state.then, andThen);
    });
  }

  it("ignores every other event without changing anything", () => {
    const listed = new Set(TABLE.map(([from, event]) => `${from}/${event}`));
    CLOSING.forEach(([, event]) => listed.add(`closing/${event}`));
    for (const from of spark.STATES) {
      for (const event of spark.EVENTS) {
        if (listed.has(`${from}/${event}`)) continue;
        const state = { name: from, attempts: 2, ...(from === "closing" ? { then: "idle" } : {}) };
        const result = spark.next(state, { type: event, online: true });
        assert.equal(result.state, state, `${from} + ${event} must be ignored`);
        assert.deepEqual(result.effects, []);
      }
    }
  });

  it("goes offline instead of backing off when the browser has no network", () => {
    for (const from of ["connecting", "joining", "open"]) {
      for (const event of ["closed", "dead"]) {
        const result = spark.next({ name: from, attempts: 1 }, { type: event, online: false });
        assert.equal(result.state.name, "offline");
        assert.equal(result.state.attempts, 1);
        assert.ok(!result.effects.some((effect) => effect.type === "backoff"));
      }
    }
  });

  it("does not leave backoff or offline on a visible tab while the browser has no network", () => {
    for (const from of ["backoff", "offline"]) {
      assert.equal(spark.next({ name: from, attempts: 4 }, { type: "visible", online: false }).state.name, from);
    }
  });

  it("keeps the attempts when a hidden tab becomes visible during backoff (no reset while the server is down)", () => {
    assert.equal(spark.next({ name: "backoff", attempts: 5 }, { type: "visible", online: true }).state.attempts, 5);
  });

  it("asks the server for a sign of life when a tab becomes visible with an open connection", () => {
    for (const from of ["joining", "open"]) {
      const result = spark.next({ name: from, attempts: 0 }, { type: "visible", online: true });
      assert.deepEqual(result.effects, [{ type: "probe" }]);
    }
  });

  it("maps states to the public status", () => {
    const status = (name, attempts = 0) => spark.statusOf({ name, attempts });
    assert.equal(status("connecting"), "connecting");
    assert.equal(status("connecting", 1), "reconnecting");
    assert.equal(status("joining"), "connected");
    assert.equal(status("open"), "connected");
    for (const name of ["idle", "closing", "backoff", "offline", "hidden-idle", "stopped"]) assert.equal(status(name), "disconnected");
  });
});

describe("runner", () => {
  it("owns one set of timers per state and cancels them when the state changes", () => {
    const h = harness(spark);
    h.machine.dispatch({ type: "connect" });
    assert.equal(h.machine.timers(), 1, "connecting: the connect watch");
    h.machine.frame();
    h.machine.dispatch({ type: "hello" });
    assert.equal(h.machine.timers(), 3, "joining: heartbeat, watchdog, join watch");
    h.machine.dispatch({ type: "joins_settled" });
    assert.equal(h.machine.timers(), 2, "open: heartbeat, watchdog");
    h.machine.dispatch({ type: "closed", code: 1006 });
    assert.equal(h.machine.state.name, "backoff");
    assert.equal(h.machine.timers(), 1, "backoff: the retry timer");
    assert.equal(h.clock.pending(), 1);
    h.machine.dispatch({ type: "stop" });
    assert.equal(h.machine.state.name, "stopped");
    assert.equal(h.clock.pending(), 0);
  });

  it("leaves no timer behind after stop, from every state", () => {
    const entries = {
      connecting: (h) => h.machine.dispatch({ type: "connect" }),
      joining: (h) => { h.machine.dispatch({ type: "connect" }); h.machine.dispatch({ type: "hello" }); },
      open,
      backoff: (h) => { open(h); h.machine.dispatch({ type: "closed", code: 1006 }); },
      offline: (h) => { open(h); h.status.online = false; h.machine.dispatch({ type: "offline" }); },
    };
    for (const [name, enter] of Object.entries(entries)) {
      const h = harness(spark);
      enter(h);
      assert.equal(h.machine.state.name, name);
      h.machine.dispatch({ type: "stop" });
      h.machine.dispatch({ type: "closed", code: 1000 });
      assert.equal(h.machine.state.name, "stopped", name);
      assert.equal(h.machine.timers(), 0, `${name}: machine timers`);
      assert.equal(h.clock.pending(), 0, `${name}: pending timers`);
      h.clock.advance(120000);
      assert.equal(h.machine.state.name, "stopped");
    }
  });

  it("gives up waiting for a close that never arrives", () => {
    const h = harness(spark);
    open(h);
    h.machine.dispatch({ type: "stop" });
    assert.equal(h.machine.state.name, "closing");
    h.clock.advance(3001);
    assert.equal(h.machine.state.name, "stopped");
    assert.ok(h.names().includes("teardown"));
    assert.equal(h.clock.pending(), 0);
  });

  it("abandons a socket that never greets the client", () => {
    const h = harness(spark);
    h.machine.dispatch({ type: "connect" });
    h.clock.advance(10001);
    assert.equal(h.machine.state.name, "backoff");
    assert.ok(h.log.some((entry) => entry.name === "close" && entry.code === 4000 && entry.reason === "connect timeout"));
  });

  it("reconnects after the backoff delay, with the attempt counted", () => {
    const h = harness(spark, { random: () => 0.5 });
    open(h);
    h.machine.dispatch({ type: "closed", code: 1006 });
    assert.deepEqual(h.log.find((entry) => entry.name === "backingOff"), { name: "backingOff", delay: 250, attempts: 1 });
    h.clock.advance(249);
    assert.equal(h.machine.state.name, "backoff");
    h.clock.advance(1);
    assert.equal(h.machine.state.name, "connecting");
    assert.equal(h.machine.state.attempts, 1);
    assert.equal(h.log.filter((entry) => entry.name === "open").length, 2);
  });

  it("emits status changes in order, before the effects of the transition", () => {
    const h = harness(spark);
    open(h);
    h.log.length = 0;
    h.machine.dispatch({ type: "closed", code: 1006, reason: "x" });
    assert.deepEqual(h.names(), ["status", "teardown", "backingOff"]);
    assert.equal(h.log[0].status, "disconnected");
  });

  it("resets the backoff only after the connection stayed open long enough", () => {
    const h = harness(spark);
    open(h);
    h.machine.dispatch({ type: "closed", code: 1006 });
    h.clock.advance(500);
    h.machine.frame();
    h.machine.dispatch({ type: "hello" });
    h.machine.dispatch({ type: "joins_settled" });
    assert.equal(h.machine.state.attempts, 1, "a connection that opens does not reset the backoff");
    // The server answers every second but the connection flaps before it proved stable.
    for (let second = 0; second < 5; second++) { h.clock.advance(1000); h.machine.frame(); }
    h.machine.dispatch({ type: "closed", code: 1006 });
    assert.equal(h.machine.state.attempts, 2, "a flapping server keeps backing off");
    h.clock.advance(1000);
    h.machine.dispatch({ type: "closed", code: 1006 });
    h.clock.advance(5000);
    assert.equal(h.machine.state.name, "connecting");
    h.machine.frame();
    h.machine.dispatch({ type: "hello" });
    h.machine.dispatch({ type: "joins_settled" });
    const attempts = h.machine.state.attempts;
    assert.ok(attempts >= 2);
    for (let second = 0; second < 11; second++) { h.clock.advance(1000); h.machine.frame(); }
    assert.equal(h.machine.state.name, "open");
    assert.equal(h.machine.state.attempts, 0, "stable for 10 s: the backoff starts over");
  });

  it("the online event resets the backoff and reconnects at once", () => {
    const h = harness(spark);
    open(h);
    h.status.online = false;
    h.machine.dispatch({ type: "closed", code: 1006 });
    assert.equal(h.machine.state.name, "offline");
    assert.equal(h.clock.pending(), 0, "nothing runs while offline");
    h.status.online = true;
    h.machine.dispatch({ type: "online" });
    assert.equal(h.machine.state.name, "connecting");
    assert.equal(h.machine.state.attempts, 0);
  });

  it("keeps the attempts across visibility changes while the server is down", () => {
    const h = harness(spark);
    open(h);
    h.machine.dispatch({ type: "closed", code: 1006 });
    h.machine.dispatch({ type: "connecting" });
    h.clock.advance(250);
    h.machine.dispatch({ type: "closed", code: 1006 });
    const attempts = h.machine.state.attempts;
    h.machine.dispatch({ type: "hidden" });
    h.machine.dispatch({ type: "visible" });
    assert.equal(h.machine.state.name, "connecting");
    assert.equal(h.machine.state.attempts, attempts);
  });

  it("handles events raised by effects after the current transition", () => {
    const h = harness(spark);
    h.machine.dispatch({ type: "connect" });
    h.machine.dispatch({ type: "dead" });
    assert.equal(h.machine.state.name, "backoff");
  });
});

describe("backoff", () => {
  it("is a uniform random delay between 0 and a doubling, capped ceiling (full jitter)", () => {
    for (let attempt = 0; attempt < 12; attempt++) {
      const ceiling = Math.min(15000, 500 * 2 ** attempt);
      assert.equal(spark.backoff(attempt, () => 0), 0);
      assert.equal(spark.backoff(attempt, () => 0.999999), ceiling);
      assert.equal(spark.backoff(attempt, () => 0.5), Math.round(ceiling / 2));
    }
  });

  it("never exceeds the cap, however many attempts", () => {
    for (const attempt of [8, 20, 100, 5000]) assert.ok(spark.backoff(attempt, () => 0.999999) <= 15000);
  });

  it("spreads clients over the whole interval", () => {
    let seed = 42;
    const random = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
    const delays = Array.from({ length: 5000 }, () => spark.backoff(3, random));
    const mean = delays.reduce((a, b) => a + b, 0) / delays.length;
    assert.ok(Math.abs(mean - 2000) < 100, `mean ${mean} should be near half of the 4000 ms ceiling`);
    assert.ok(Math.min(...delays) < 100 && Math.max(...delays) > 3900);
    const buckets = new Array(8).fill(0);
    delays.forEach((delay) => buckets[Math.min(7, Math.floor(delay / 500))]++);
    buckets.forEach((count) => assert.ok(count > 5000 / 8 * 0.8 && count < 5000 / 8 * 1.2, `buckets ${buckets}`));
  });
});

describe("heartbeat", () => {
  const measure = (silence, gap = 1000) => ({ silence, gap, interval: 1000, period: 1000 });

  it("judges silence against 2.5 intervals", () => {
    assert.equal(spark.heartbeatVerdict(measure(0)), "alive");
    assert.equal(spark.heartbeatVerdict(measure(2500)), "alive");
    assert.equal(spark.heartbeatVerdict(measure(2501)), "dead");
  });

  it("does not call a connection dead when its own timer ran late", () => {
    assert.equal(spark.heartbeatVerdict(measure(60000, 60000)), "suspect");
    assert.equal(spark.heartbeatVerdict(measure(60000, 2001)), "suspect");
    assert.equal(spark.heartbeatVerdict(measure(60000, 2000)), "dead");
  });

  it("drops a connection that goes silent", () => {
    const h = harness(spark);
    open(h);
    for (let second = 0; second < 2; second++) { h.clock.advance(1000); h.machine.frame(); }
    h.clock.advance(2000);
    assert.equal(h.machine.state.name, "open", "silent for 2 s is still fine");
    h.clock.advance(1000);
    assert.equal(h.machine.state.name, "backoff");
    assert.ok(h.log.some((entry) => entry.name === "close" && entry.reason === "heartbeat timeout" && entry.code === 4000));
  });

  it("sends a heartbeat every interval", () => {
    const h = harness(spark);
    open(h);
    for (let second = 0; second < 3; second++) { h.clock.advance(1000); h.machine.frame(); }
    assert.equal(h.status.beats, 3);
  });

  it("asks instead of dropping when a throttled timer wakes up late, and keeps a connection that answers", () => {
    const h = harness(spark);
    open(h);
    h.clock.jump(5 * 60 * 1000); // a background tab: every timer runs once, minutes late
    assert.equal(h.machine.state.name, "open", "no verdict from a late watchdog");
    assert.ok(h.status.beats >= 1, "the server was asked");
    h.machine.frame(); // the answer, which sat in the queue behind the timer
    for (let second = 0; second < 5; second++) { h.clock.advance(1000); h.machine.frame(); }
    assert.equal(h.machine.state.name, "open");
  });

  it("drops a throttled tab's connection when the server stays silent after being asked", () => {
    const h = harness(spark);
    open(h);
    h.clock.jump(5 * 60 * 1000);
    assert.equal(h.machine.state.name, "open");
    h.clock.advance(3000);
    assert.notEqual(h.machine.state.name, "open");
    assert.ok(h.log.some((entry) => entry.name === "close" && entry.reason === "heartbeat timeout"));
  });

  it("waits once more when the probe timer itself runs late", () => {
    const h = harness(spark);
    open(h);
    h.clock.jump(5 * 60 * 1000);
    const beats = h.status.beats;
    h.clock.jump(60000); // the probe timeout fires a minute late
    assert.equal(h.machine.state.name, "open");
    assert.ok(h.status.beats > beats, "asked again instead of judging");
    h.clock.advance(3000);
    assert.notEqual(h.machine.state.name, "open");
    assert.ok(h.log.some((entry) => entry.name === "close" && entry.reason === "heartbeat timeout"));
  });

  it("probes when the tab becomes visible (the probe was swallowed by a comment before)", () => {
    const h = harness(spark);
    open(h);
    h.machine.frame();
    const beats = h.status.beats;
    h.machine.dispatch({ type: "visible" });
    assert.equal(h.status.beats, beats + 1, "a heartbeat is sent at once");
    h.clock.advance(3001);
    assert.equal(h.machine.state.name, "backoff", "and no answer means the connection is dropped");
  });

  it("keeps the connection when the probe is answered", () => {
    const h = harness(spark);
    open(h);
    h.machine.dispatch({ type: "visible" });
    h.clock.advance(100);
    h.machine.frame();
    h.clock.advance(2000);
    h.machine.frame();
    assert.equal(h.machine.state.name, "open");
  });

  it("does nothing when the heartbeat cannot be sent", () => {
    const h = harness(spark);
    open(h);
    h.status.canSend = false;
    h.machine.dispatch({ type: "visible" });
    assert.equal(h.machine.timers(), 2);
  });
});

// Event delivery: coalescing, ordering, ids and acks, the bounded queue, resending after a reconnect.
// The client talks to a fake WebSocket the test plays the server of.
import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { FakeSocket, connected, loadSpark, tick, until } from "./helpers.mjs";

const ROOT = `
  <div data-spark-root data-spark-id="r" data-spark-token="t">
    <input id="a" name="a" spark-change="set">
    <input id="b" name="b" spark-change="set">
    <input id="c" type="checkbox" name="c" spark-change="toggle">
    <button id="go" spark-click="go">go</button>
    <button id="once" spark-click="pay" spark-delivery="at-most-once">pay</button>
    <div data-spark-id="r2"><button id="other" spark-click="other">other</button></div>
  </div>
  <div data-spark-root data-spark-id="s" data-spark-token="u"><button id="apart" spark-click="apart">apart</button></div>`;

let spark;
let dropped;
const hear = (detail) => dropped.push(detail);
const $ = (id) => document.getElementById(id);

function type(id, value) {
  $(id).value = value;
  $(id).dispatchEvent(new window.Event("input", { bubbles: true }));
}
const click = (id) => $(id).dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
const reply = (socket, frame) => socket.receive({ type: "reply", id: frame.id, target: frame.target });
const values = (socket) => socket.events.map((frame) => frame.payload.value ?? frame.event);

beforeEach(async () => {
  spark = await loadSpark();
  document.body.innerHTML = ROOT;
  dropped = [];
  window.AzuSpark.on("event_dropped", hear);
  await tick();
});

afterEach(async () => {
  window.AzuSpark.disconnect();
  await tick(5);
  window.AzuSpark.off("event_dropped", hear);
});

describe("event ids", () => {
  it("numbers events per page with increasing ids", async () => {
    const socket = await connected();
    click("go"); click("go"); click("other");
    const eids = socket.events.map((frame) => frame.eid);
    assert.equal(eids.length, 3);
    assert.ok(eids.every((eid, i) => Number.isInteger(eid) && (i === 0 || eid > eids[i - 1])), `increasing: ${eids}`);
  });

  it("keeps counting across a reconnect: a new event never reuses a number", async () => {
    const first = await connected();
    click("go");
    reply(first, first.events[0]);
    first.drop();
    const second = await connected();
    click("go");
    assert.ok(second.events[0].eid > first.events[0].eid);
  });

  it("stamps events with the generation of their component tree when the server named one", async () => {
    const socket = await connected({ gen: "g1" });
    click("go");
    assert.equal(socket.events[0].gen, "g1");
  });

  it("sends no generation when the server named none", async () => {
    const socket = await connected();
    click("go");
    assert.equal("gen" in socket.events[0], false);
  });
});

describe("coalescing", () => {
  it("keeps only the latest value of a control while an earlier one is in flight", async () => {
    const socket = await connected();
    type("a", "1");
    type("a", "12");
    type("a", "123");
    type("a", "1234");
    assert.deepEqual(values(socket), ["1"], "one in flight, the rest wait");
    assert.equal(window.AzuSpark.queued, 1, "the waiting ones are one entry");
    reply(socket, socket.events[0]);
    assert.deepEqual(values(socket), ["1", "1234"]);
  });

  it("delivers the latest value of each of two controls edited while offline", async () => {
    const socket = await connected();
    socket.drop();
    type("a", "x"); type("a", "xy"); type("b", "p"); type("b", "pq");
    const next = await connected();
    const sent = next.events.map((frame) => frame.payload.a ?? frame.payload.b).sort();
    assert.deepEqual(sent, ["pq", "xy"]);
  });

  it("merges a control's newer value across the value edits of other controls, but not across other events", async () => {
    const socket = await connected();
    socket.drop();
    type("a", "1"); type("b", "x"); type("a", "12");
    assert.equal(window.AzuSpark.queued, 2);
    click("go");
    type("a", "123");
    assert.equal(window.AzuSpark.queued, 4, "the click is a barrier");
    const next = await connected();
    assert.deepEqual(next.events.map((frame) => frame.payload.value ?? frame.event), ["12", "x", "go"], "the last value waits for the first to be answered");
  });

  it("does not merge a checkbox or a select: every change is its own event", async () => {
    const socket = await connected();
    $("c").checked = true; $("c").dispatchEvent(new window.Event("change", { bubbles: true }));
    $("c").checked = false; $("c").dispatchEvent(new window.Event("change", { bubbles: true }));
    $("c").checked = true; $("c").dispatchEvent(new window.Event("change", { bubbles: true }));
    assert.deepEqual(socket.events.map((frame) => frame.payload.value), [true, false, true]);
  });

  it("does not merge across a click on the same component", async () => {
    const socket = await connected();
    type("a", "1");
    type("a", "12");
    click("go");
    type("a", "123");
    assert.deepEqual(values(socket), ["1"]);
    reply(socket, socket.events[0]);
    assert.deepEqual(values(socket), ["1", "12", "go"], "values and the click keep the user's order");
    reply(socket, socket.events[1]);
    reply(socket, socket.events[2]);
    assert.deepEqual(values(socket), ["1", "12", "go", "123"]);
  });

  it("waits for an earlier value before anything else of the same root, also another component of it", async () => {
    const socket = await connected();
    type("a", "1");
    type("a", "12");
    click("other");
    assert.deepEqual(values(socket), ["1"]);
    reply(socket, socket.events[0]);
    assert.deepEqual(values(socket), ["1", "12", "other"]);
  });

  it("does not hold back another root", async () => {
    const socket = await connected();
    type("a", "1");
    type("a", "12");
    click("apart");
    assert.deepEqual(values(socket), ["1", "apart"]);
  });

  it("never merges a newer value into an event that was already sent once", async () => {
    const socket = await connected();
    type("a", "1");
    socket.drop();
    type("a", "12"); // "1" may have been applied: it must be resent as it was, "12" is a second event
    const next = await connected();
    assert.deepEqual(values(next), ["1"]);
    assert.equal(next.events[0].eid, socket.events[0].eid);
    reply(next, next.events[0]);
    assert.deepEqual(values(next), ["1", "12"]);
  });
});

describe("resending", () => {
  it("resends unacknowledged events after a reconnect, in order and with their ids", async () => {
    const socket = await connected();
    click("go"); click("other"); click("go");
    reply(socket, socket.events[0]);
    socket.drop();
    click("other"); // typed while reconnecting
    const next = await connected();
    assert.deepEqual(next.events.map((frame) => frame.event), ["other", "go", "other"]);
    assert.deepEqual(next.events.slice(0, 2).map((frame) => frame.eid), socket.events.slice(1).map((frame) => frame.eid));
    assert.ok(next.events[2].eid > next.events[1].eid);
  });

  it("does not resend an event whose diff carried the ack, even though its reply never came", async () => {
    const socket = await connected();
    click("go");
    socket.receive({ type: "diff", seq: 1, patches: [], events: [], snapshots: {}, ack: socket.events[0].eid });
    assert.equal(window.AzuSpark.unacked, 0);
    socket.drop();
    const next = await connected();
    assert.equal(next.events.length, 0);
  });

  it("forgets an event whose ack arrived with a diff even if the connection closes before the patches are applied", async () => {
    const socket = await connected();
    click("go");
    socket.receive({ type: "diff", seq: 1, patches: [{ id: "r", html: "<i></i>" }], events: [], snapshots: { r: "s2" }, ack: socket.events[0].eid });
    socket.drop(); // before the animation frame that applies the patch
    const next = await connected();
    assert.equal(next.events.length, 0, "it was applied: the snapshot the page rejoins with already holds it");
    assert.equal(next.of("join")[0].snapshot, "s2");
  });

  it("forgets an event whose reply arrived behind a patch even if the connection closes before the frame", async () => {
    const socket = await connected();
    click("go");
    socket.receive({ type: "diff", seq: 1, patches: [{ id: "r", html: "<i></i>" }], events: [], snapshots: {} });
    reply(socket, socket.events[0]);
    socket.drop();
    const next = await connected();
    assert.equal(next.events.length, 0);
  });

  it("does not send the next value of a control before the patch that came with the answer is painted", async () => {
    const socket = await connected();
    type("a", "1");
    socket.receive({ type: "diff", seq: 1, patches: [{ id: "r", html: "<i></i>" }], events: [], snapshots: {}, ack: socket.events[0].eid });
    reply(socket, socket.events[0]);
    type("a", "12"); // before the animation frame
    assert.equal(socket.events.length, 1, "an older patch would be written over the newer text");
    spark.flushPatches();
    assert.deepEqual(values(socket), ["1", "12"], "sent right after the paint");
  });

  it("treats a rate_limited answer as the end of that event and reports it", async () => {
    const socket = await connected();
    click("go");
    socket.receive({ type: "error", id: socket.events[0].id, code: "rate_limited", message: "x", ack: socket.events[0].eid });
    assert.equal(window.AzuSpark.unacked, 0);
    assert.deepEqual(dropped, [{ event: "go", reason: "rate_limited" }]);
  });

  it("clears an event on its reply, also when the server says it was a duplicate", async () => {
    const socket = await connected();
    click("go");
    socket.receive({ type: "reply", id: socket.events[0].id, target: "r", dup: true });
    assert.equal(window.AzuSpark.unacked, 0);
  });

  it("drops an at-most-once event with the connection instead of resending it", async () => {
    const socket = await connected();
    click("once");
    socket.drop();
    const next = await connected();
    assert.equal(next.events.length, 0);
    assert.deepEqual(dropped, [{ event: "pay", reason: "disconnect" }]);
  });

  it("drops an event the server calls stale, and does not retry it", async () => {
    const socket = await connected({ gen: "g1" });
    click("go");
    socket.receive({ type: "error", id: socket.events[0].id, code: "stale_event", message: "stale" });
    assert.deepEqual(dropped, [{ event: "go", reason: "stale" }]);
    socket.drop();
    const next = await connected();
    assert.equal(next.events.length, 0);
  });

  it("answers a join with a new generation by stamping later events with it", async () => {
    const socket = await connected({ gen: "g1" });
    socket.drop();
    const next = await connected({ gen: "g2" });
    click("go");
    assert.equal(next.events[0].gen, "g2");
  });

  it("drops events when the client is stopped on purpose", async () => {
    const socket = await connected();
    click("go");
    window.AzuSpark.disconnect();
    assert.equal(window.AzuSpark.unacked, 0);
    assert.equal(window.AzuSpark.queued, 0);
    assert.deepEqual(dropped, [{ event: "go", reason: "stopped" }]);
    void socket;
  });
});

describe("the bounded queue", () => {
  it("keeps at most 50 events and reports each dropped one, oldest first", async () => {
    const socket = await connected();
    socket.drop();
    for (let i = 0; i < 60; i++) click(i % 2 ? "go" : "other");
    assert.equal(window.AzuSpark.queued, 50);
    assert.equal(dropped.length, 10);
    assert.ok(dropped.every((entry) => entry.reason === "queue_full"));
  });

  it("drops the oldest event when full, also when it is in flight and a newer one waits", async () => {
    const socket = await connected();
    type("a", "1"); // in flight
    type("a", "12"); // waits for it, and holds back what follows
    for (let i = 0; i < 48; i++) click("go");
    assert.equal(window.AzuSpark.unacked + window.AzuSpark.queued, 50);
    click("go");
    assert.equal(dropped.length, 1);
    assert.equal(window.AzuSpark.unacked, 0, "the text in flight was the oldest, not the one that waits");
    void socket;
  });

  it("counts unacknowledged events against the same bound", async () => {
    const socket = await connected();
    for (let i = 0; i < 60; i++) click("go");
    assert.equal(socket.events.length, 60, "all were sent");
    assert.ok(window.AzuSpark.unacked + window.AzuSpark.queued <= 50);
    assert.equal(dropped.length, 10);
  });

  it("forgets events older than the age limit instead of resending them", async (t) => {
    const socket = await connected();
    click("go");
    socket.drop();
    t.mock.method(performance, "now", () => 120000 + Date.now() % 1000 + 1e6);
    const next = await connected();
    assert.equal(next.events.length, 0);
    assert.equal(dropped[0].reason, "expired");
  });
});

describe("loading states", () => {
  it("keeps spark-disable-with active while the event waits to be resent", async () => {
    const button = $("go");
    button.setAttribute("spark-disable-with", "Saving");
    const socket = await connected();
    click("go");
    assert.equal(button.textContent, "Saving");
    socket.drop();
    assert.equal(button.textContent, "Saving");
    const next = await connected();
    reply(next, next.events[0]);
    assert.equal(button.textContent, "go");
    await until(() => true);
  });
});

// Accessibility: one polite live region for reconnecting/offline/stale, aria-busy while an event is in flight.
import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { FakeSocket, connected, loadSpark, tick, until } from "./helpers.mjs";

let spark;
const ROOT = `<div id="root" data-spark-root data-spark-id="r" data-spark-token="t">
  <input id="a" name="a" spark-change="set"><button id="go" spark-click="go">go</button>
  <button id="pay" spark-click="pay" spark-delivery="at-most-once">pay</button><p id="inside" data-spark-live-region></p></div>`;
const $ = (id) => document.getElementById(id);
const click = (id) => $(id).dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
const regions = () => [...document.querySelectorAll("[aria-live]")];
const said = () => (regions()[0] ? regions()[0].textContent : "");

beforeEach(async () => {
  spark = await loadSpark();
  spark.resetAnnouncements();
  document.body.innerHTML = ROOT;
  window.AzuSpark.configure({ live: true, text: {} });
  await tick();
});

afterEach(async () => {
  window.AzuSpark.disconnect();
  await tick(5);
  document.querySelectorAll("[aria-live]").forEach((el) => el.remove());
  window.AzuSpark.configure({ live: true, text: {} });
});

describe("live region", () => {
  it("does not exist until something is announced, and then there is exactly one", async () => {
    const socket = await connected();
    assert.equal(regions().length, 0);
    socket.drop(); // reconnecting waits a second before it says anything
    await until(() => said() === "Reconnecting...", "the announcement", 6000);
    assert.equal(regions().length, 1);
    const [region] = regions();
    assert.equal(region.getAttribute("aria-live"), "polite");
    assert.equal(region.getAttribute("role"), "status");
    assert.ok(region.classList.contains("azu-spark-live"));
    assert.equal(region.style.position, "absolute", "hidden visually through CSSOM, not markup");
  });

  it("a reconnect that is quick says nothing; one that was announced says it is back", async () => {
    const first = await connected();
    let before = FakeSocket.all.length;
    first.drop();
    const quick = await connected({ before });
    assert.equal(regions().length, 0, "back before the delay: silence");
    before = FakeSocket.all.length;
    quick.drop();
    await until(() => said() === "Reconnecting...", "the announcement", 6000);
    await connected({ before });
    await until(() => said() === "Back online.", "the all clear", 3000);
    assert.equal(regions().length, 1);
  });

  it("a dropped at-most-once event does not swallow the connection announcements", async () => {
    const socket = await connected();
    const heard = [];
    const watch = setInterval(() => { if (said() && heard.at(-1) !== said()) heard.push(said()); }, 5);
    click("pay");
    const before = FakeSocket.all.length;
    socket.drop(); // the event in flight is dropped (stale), and the connection is lost
    await until(() => heard.includes("Reconnecting..."), "reconnecting", 6000);
    await connected({ before });
    await until(() => heard.includes("Back online."), "the all clear", 3000);
    clearInterval(watch);
    assert.deepEqual(heard, ["This page may be out of date.", "Reconnecting...", "Back online."]);
  });

  it("announces stale every time, not once", async () => {
    const socket = await connected();
    const stale = async () => {
      click("go");
      const frame = socket.events.at(-1);
      socket.receive({ type: "error", id: frame.id, code: "stale_event", message: "x" });
      await until(() => said() === "This page may be out of date.", "the announcement", 3000);
    };
    await stale();
    socket.receive({ type: "heartbeat", id: 0 });
    click("go");
    const frame = socket.events.at(-1);
    socket.receive({ type: "error", id: frame.id, code: "stale_event", message: "x" });
    await until(() => said() === "", "the region is blanked so the same words are read again", 3000);
    await until(() => said() === "This page may be out of date.", "the announcement again", 3000);
  });

  it("clears the region on restored even when that text is empty", async () => {
    window.AzuSpark.configure({ text: { restored: "" } });
    const first = await connected();
    const before = FakeSocket.all.length;
    first.drop();
    await until(() => said() === "Reconnecting...", "reconnecting", 6000);
    await connected({ before });
    await until(() => said() === "", "the region cleared", 3000);
  });

  it("ignores a live region inside a Spark root, which a patch could overwrite", async () => {
    const socket = await connected();
    socket.drop();
    await until(() => regions().length === 1 && said() !== "", "the announcement", 6000);
    assert.equal($("inside").textContent, "");
    assert.equal(regions()[0].parentNode, document.body);
  });

  it("a pending announcement is dropped when the tab goes idle", async () => {
    window.AzuSpark.configure({ hiddenIdle: 30 });
    const socket = await connected();
    socket.drop();
    Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true });
    document.dispatchEvent(new window.Event("visibilitychange"));
    await until(() => window.AzuSpark.stats().state === "hidden-idle", "hidden-idle", 3000);
    await tick(1300);
    assert.equal(regions().length, 0);
    Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true });
    document.dispatchEvent(new window.Event("visibilitychange"));
    window.AzuSpark.configure({ hiddenIdle: 300000 });
  });

  // Everything the region said, in order (it is blanked between messages).
  function listen() {
    const heard = [];
    const timer = setInterval(() => { if (said() && heard.at(-1) !== said()) heard.push(said()); }, 5);
    return { heard, stop: () => clearInterval(timer) };
  }

  it("speaks overlapping announcements one after the other: offline and stale in the same tick", async () => {
    const socket = await connected();
    const { heard, stop } = listen();
    click("go");
    socket.receive({ type: "error", id: socket.events[0].id, code: "stale_event", message: "x" });
    window.dispatchEvent(new window.Event("offline"));
    await until(() => heard.length === 2, "both messages", 3000);
    stop();
    assert.deepEqual([...heard].sort(), ["Offline. Live updates are paused.", "This page may be out of date."]);
  });

  it("speaks stale and then restored when they land together", async () => {
    const first = await connected();
    const before = FakeSocket.all.length;
    first.drop();
    await until(() => said() === "Reconnecting...", "reconnecting", 6000);
    const { heard, stop } = listen();
    const second = await connected({ before });
    click("go");
    second.receive({ type: "error", id: second.events[0].id, code: "stale_event", message: "x" });
    await until(() => heard.includes("Back online.") && heard.includes("This page may be out of date."), "both messages", 3000);
    stop();
  });

  it("a stopped client announces nothing it was about to say", async () => {
    const socket = await connected();
    socket.drop();
    await tick(100);
    window.AzuSpark.disconnect();
    await tick(1300);
    assert.equal(regions().length, 0, "no Reconnecting... on a stopped client");
    const before = FakeSocket.all.length;
    window.AzuSpark.connect();
    await connected({ before });
    assert.equal(regions().length, 0, "and no stale all clear: nothing was said");
  });

  it("announces offline", async () => {
    await connected();
    window.dispatchEvent(new window.Event("offline"));
    await until(() => said() === "Offline. Live updates are paused.", "the announcement", 3000);
  });

  it("announces a stale event", async () => {
    const socket = await connected();
    click("go");
    const frame = socket.events[0];
    socket.receive({ type: "error", id: frame.id, code: "stale_event", message: "x" });
    await until(() => said() === "This page may be out of date.", "the announcement", 3000);
  });

  it("takes its words from the dictionary, and an empty word is silence", async () => {
    window.AzuSpark.configure({ text: { stale: "Veraltet", offline: "" } });
    const socket = await connected();
    click("go");
    socket.receive({ type: "error", id: socket.events[0].id, code: "stale_event", message: "x" });
    await until(() => said() === "Veraltet", "the announcement", 3000);
    window.dispatchEvent(new window.Event("offline"));
    await tick(400);
    assert.equal(said(), "Veraltet", "an empty text announces nothing");
  });

  it("can be switched off", async () => {
    window.AzuSpark.configure({ live: false });
    const socket = await connected();
    socket.drop();
    await tick(1200);
    assert.equal(regions().length, 0);
  });

  it("uses a region the page provides instead of making another", async () => {
    document.body.insertAdjacentHTML("beforeend", '<p data-spark-live-region aria-live="polite" id="mine"></p>');
    const socket = await connected();
    socket.drop();
    await until(() => $("mine").textContent === "Reconnecting...", "the announcement", 6000);
    assert.equal(regions().length, 1);
  });

  it("never moves focus", async () => {
    const socket = await connected();
    $("a").focus();
    socket.drop();
    await until(() => regions().length === 1 && said() !== "", "the announcement", 6000);
    assert.equal(document.activeElement, $("a"));
  });
});

describe("aria-busy", () => {
  const busy = () => $("root").getAttribute("aria-busy");

  it("is not set for an answer that comes quickly, without flicker", async () => {
    const socket = await connected();
    spark.config.busyDelay = 1500; // far from the 30 ms of the answer, however slow the machine
    const seen = [];
    new window.MutationObserver((records) => records.forEach((r) => r.attributeName === "aria-busy" && seen.push(busy()))).observe($("root"), { attributes: true });
    click("go");
    await tick(30);
    const frame = socket.events[0];
    socket.receive({ type: "reply", id: frame.id, target: frame.target });
    await tick(250);
    assert.deepEqual(seen, [], "never touched");
    assert.equal(busy(), null);
    spark.config.busyDelay = 150;
  });

  it("is set on the root of an event still unanswered after the delay, and cleared with the answer", async () => {
    const socket = await connected();
    click("go");
    assert.equal(busy(), null);
    await until(() => busy() === "true", "aria-busy", 3000);
    const frame = socket.events[0];
    socket.receive({ type: "reply", id: frame.id, target: frame.target });
    await tick(80);
    assert.equal(busy(), null);
  });

  it("counts events: it stays until the last one is answered", async () => {
    const socket = await connected();
    click("go"); click("go");
    await until(() => busy() === "true", "aria-busy", 3000);
    socket.receive({ type: "reply", id: socket.events[0].id, target: "r" });
    await tick(80);
    assert.equal(busy(), "true");
    socket.receive({ type: "reply", id: socket.events[1].id, target: "r" });
    await tick(80);
    assert.equal(busy(), null);
  });

  it("is cleared when the client stops and drops what it held", async () => {
    await connected();
    click("go");
    await until(() => busy() === "true", "aria-busy", 3000);
    window.AzuSpark.disconnect();
    await tick(20);
    assert.equal(busy(), null);
  });
});

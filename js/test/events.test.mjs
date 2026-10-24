// The event pipeline: delegation, passive listeners, composition, debounce/throttle with trailing flush.
import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { FakeSocket, connected, loadSpark, tick } from "./helpers.mjs";

const listeners = []; // [target, type, options] as registered on the document (by the client)
const strays = []; // listeners added to anything but the document and window

const ROOT = `
  <div data-spark-root data-spark-id="r" data-spark-token="t">
    <input id="a" name="a" spark-change="set">
    <input id="slow" name="slow" spark-change="set" spark-debounce="30">
    <input id="keys" name="keys" spark-keydown="enter" spark-key="Enter">
    <form id="f" spark-submit="save"><input id="inf" name="inf" spark-change="set" spark-debounce="500"><button>go</button></form>
    <button id="go" spark-click="go">go</button>
  </div>`;

const $ = (id) => document.getElementById(id);
const input = (id, init = {}) => $(id).dispatchEvent(new window.InputEvent("input", { bubbles: true, ...init }));
const names = (socket) => socket.events.map((frame) => frame.event);

beforeEach(async () => {
  await loadSpark((window) => {
    let owner = window.document;
    while (!Object.prototype.hasOwnProperty.call(owner, "addEventListener")) owner = Object.getPrototypeOf(owner);
    const add = owner.addEventListener;
    owner.addEventListener = function (type, fn, options) {
      if (this === window.document) listeners.push([type, options]);
      else if (this !== window) strays.push(type);
      return add.call(this, type, fn, options);
    };
  });
  document.body.innerHTML = ROOT;
  await tick();
});

afterEach(async () => {
  window.AzuSpark.disconnect();
  await tick(5);
});

describe("delegation", () => {
  it("listens once per event type on the document, not per element", async () => {
    const socket = await connected();
    const before = strays.length;
    const extra = Array.from({ length: 50 }, (_, i) => `<input name="n${i}" spark-change="set">`).join("");
    $("go").parentElement.insertAdjacentHTML("beforeend", extra);
    document.querySelector('[name="n7"]').value = "x";
    document.querySelector('[name="n7"]').dispatchEvent(new window.Event("input", { bubbles: true }));
    assert.equal(socket.events.at(-1).payload.n7, "x", "an element added later works");
    assert.equal(strays.length, before, "no listener on elements");
    for (const type of ["click", "submit", "keydown", "keyup", "input", "change", "blur", "focus"]) {
      assert.equal(listeners.filter(([name]) => name === type).length, 1, `${type} listeners`);
    }
  });

  it("registers passive listeners where the handler never cancels the event", () => {
    const passive = (type) => listeners.find(([name]) => name === type)[1];
    for (const type of ["input", "change", "keyup", "blur", "focus"]) {
      assert.equal(passive(type)?.passive, true, `${type} is passive`);
    }
    for (const type of ["click", "submit", "keydown"]) {
      assert.notEqual(passive(type)?.passive, true, `${type} may preventDefault`);
    }
  });
});

describe("composition", () => {
  it("sends nothing while an IME composes and the final value when it ends", async () => {
    const socket = await connected();
    const field = $("a");
    field.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true }));
    field.value = "に"; input("a", { isComposing: true });
    field.value = "日本"; input("a", { isComposing: true });
    assert.equal(socket.events.length, 0);
    field.value = "日本語";
    field.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true, data: "日本語" }));
    assert.equal(socket.events.length, 1);
    assert.equal(socket.events[0].payload.a, "日本語");
  });

  it("merges the input some browsers fire after compositionend into the event already sent", async () => {
    const socket = await connected();
    const field = $("a");
    field.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true }));
    field.value = "é";
    field.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true }));
    input("a", { isComposing: false });
    assert.equal(socket.events.length, 1, "the second waits for the first, and carries the same value");
    assert.equal(window.AzuSpark.queued, 1);
  });

  it("ignores a key pressed to confirm a composition", async () => {
    const socket = await connected();
    $("keys").dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", isComposing: true, bubbles: true, cancelable: true }));
    assert.equal(socket.events.length, 0);
    $("keys").dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    assert.deepEqual(names(socket), ["enter"]);
  });
});

describe("spark-key", () => {
  it("only reacts to the named key and cancels only then", async () => {
    const socket = await connected();
    const other = new window.KeyboardEvent("keydown", { key: "a", bubbles: true, cancelable: true });
    $("keys").dispatchEvent(other);
    assert.equal(other.defaultPrevented, false);
    const enter = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
    $("keys").dispatchEvent(enter);
    assert.equal(enter.defaultPrevented, true);
    assert.deepEqual(names(socket), ["enter"]);
  });
});

describe("debounce", () => {
  it("sends the last value once the pause is over", async () => {
    const socket = await connected();
    for (const value of ["a", "ab", "abc"]) { $("slow").value = value; input("slow"); await tick(5); }
    assert.equal(socket.events.length, 0);
    await tick(60);
    assert.deepEqual(socket.events.map((frame) => frame.payload.value), ["abc"]);
  });

  it("flushes the pending value at once when the control loses focus", async () => {
    const socket = await connected();
    $("slow").value = "typed"; input("slow");
    $("slow").dispatchEvent(new window.FocusEvent("blur"));
    assert.deepEqual(socket.events.map((frame) => frame.payload.value), ["typed"]);
    await tick(60);
    assert.equal(socket.events.length, 1, "the timer does not send it again");
  });

  it("flushes pending values before a submit, so the server sees them in the user's order", async () => {
    const socket = await connected();
    $("inf").value = "late"; input("inf");
    $("f").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
    assert.deepEqual(names(socket), ["set", "save"]);
    assert.equal(socket.events[0].payload.value, "late");
  });

  it("flushes pending values when the page is hidden into the back/forward cache", async () => {
    const socket = await connected();
    $("inf").value = "bye"; input("inf");
    window.dispatchEvent(new window.Event("pagehide"));
    assert.equal(socket.events.length, 1);
    assert.equal(socket.events[0].payload.value, "bye");
    void FakeSocket;
  });
});

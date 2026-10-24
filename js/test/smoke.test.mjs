// Smoke tests of the Spark client module: it loads in a DOM without a Spark root (so it opens no
// socket) and its pure helpers behave. No behaviour is tested beyond what the shipped script does.
import assert from "node:assert/strict";
import { before, describe, it } from "node:test";
import { Window } from "happy-dom";

let spark;

before(async () => {
  const window = new Window({ url: "http://localhost/" });
  for (const name of ["window", "document", "location", "navigator", "DOMParser", "CustomEvent", "URL", "URLSearchParams", "MutationObserver", "Node", "Element"]) {
    if (name === "window") globalThis.window = window;
    else Object.defineProperty(globalThis, name, { value: window[name], configurable: true, writable: true });
  }
  spark = await import("../azu-spark.js");
});

describe("azu-spark.js", () => {
  it("loads, exposes the public API and opens no socket without a root", () => {
    assert.equal(window.AzuSpark.status, "disconnected");
    assert.equal(window.AzuSpark.queued, 0);
    assert.equal(window.Spark, window.AzuSpark);
    assert.equal(typeof window.AzuSpark.on, "function");
  });

  it("backs off within [0, ceiling], the ceiling doubling up to 15 s", () => {
    for (let attempt = 0; attempt < 12; attempt++) {
      const ceiling = Math.min(15000, 500 * 2 ** attempt);
      const delay = spark.backoff(attempt);
      assert.ok(delay >= 0 && delay <= ceiling, `attempt ${attempt}: ${delay} outside 0..${ceiling}`);
    }
  });

  it("only uses supported heartbeat intervals", () => {
    assert.equal(spark.heartbeatInterval(undefined), 20000);
    assert.equal(spark.heartbeatInterval("junk"), 20000);
    assert.equal(spark.heartbeatInterval(3000), 5000);
    assert.equal(spark.heartbeatInterval(1), 1000);
    assert.equal(spark.heartbeatInterval(10 ** 9), 60000);
  });

  it("recognises script URLs, whatever whitespace hides the scheme", () => {
    assert.equal(spark.scriptUrl("javascript:alert(1)", "href"), true);
    assert.equal(spark.scriptUrl(" java\tscript:alert(1)", "href"), true);
    assert.equal(spark.scriptUrl("data:text/html,x", "src"), true);
    assert.equal(spark.scriptUrl("data:image/png;base64,AAAA", "src"), false);
    assert.equal(spark.scriptUrl("/posts/1", "href"), false);
  });

  it("sanitizes a patch: no script, inline handlers or script URLs survive", () => {
    const fragment = spark.parsePatch(
      '<p onclick="x()">hi</p><script>x()</script><a href="javascript:x()">a</a><a href="/ok">b</a>',
    );
    spark.sanitize(fragment);
    const holder = window.document.createElement("div");
    holder.appendChild(fragment);
    assert.equal(holder.innerHTML, '<p>hi</p><a>a</a><a href="/ok">b</a>');
  });
});

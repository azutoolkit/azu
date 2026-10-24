// The patch engine: keyed morphing, preservation of what the user is doing, Trusted Types, scripts.
import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";
import { loadSpark } from "./helpers.mjs";

let spark;
let page;

before_all();
function before_all() {
  beforeEach(async () => {
    spark = await loadSpark();
    document.body.innerHTML = '<div id="c" data-spark-id="c"></div>';
    page = document.getElementById("c");
    delete window.trustedTypes;
  });
}

/** Sets the component's content, then patches it with *html* and flushes the frame. */
function patch(html, before) {
  if (before !== undefined) page.innerHTML = before;
  spark.applyPatch("c", html);
  spark.flushPatches();
}
const nodes = (selector) => [...page.querySelectorAll(selector)];

describe("keyed matching", () => {
  it("keeps the nodes of a reordered keyed list and moves the fewest", () => {
    page.innerHTML = "<ul><li id=a>a</li><li id=b>b</li><li id=c>c</li><li id=d>d</li></ul>";
    const [a, b, c, d] = nodes("li");
    const moves = [];
    const insert = window.Element.prototype.insertBefore;
    page.querySelector("ul").insertBefore = function (node, ref) { moves.push(node); return insert.call(this, node, ref); };
    patch("<ul><li id=b>b</li><li id=c>c</li><li id=d>d</li><li id=a>a</li></ul>");
    assert.deepEqual(nodes("li").map((n) => n.id), ["b", "c", "d", "a"]);
    assert.deepEqual(nodes("li"), [b, c, d, a], "same nodes, not copies");
    assert.deepEqual(moves, [a], "one move for a rotation");
  });

  it("moves one node when the last item goes first, not all the others", () => {
    page.innerHTML = "<ul><li id=a>a</li><li id=b>b</li><li id=c>c</li><li id=d>d</li></ul>";
    const [, , , d] = nodes("li");
    const moves = [];
    const insert = window.Element.prototype.insertBefore;
    page.querySelector("ul").insertBefore = function (node, ref) { moves.push(node); return insert.call(this, node, ref); };
    patch("<ul><li id=d>d</li><li id=a>a</li><li id=b>b</li><li id=c>c</li></ul>");
    assert.deepEqual(moves, [d]);
    assert.deepEqual(nodes("li").map((n) => n.id), ["d", "a", "b", "c"]);
  });

  it("matches by data-spark-key and updates the node in place", () => {
    page.innerHTML = '<p data-spark-key="x">one</p><p data-spark-key="y">two</p>';
    const [x, y] = nodes("p");
    patch('<p data-spark-key="y">two!</p><p data-spark-key="x">one</p>');
    assert.deepEqual(nodes("p"), [y, x]);
    assert.equal(y.textContent, "two!");
  });

  it("inserts and removes keyed nodes without touching the others", () => {
    page.innerHTML = "<i id=a>a</i><i id=b>b</i>";
    const b = document.getElementById("b");
    patch("<i id=n>n</i><i id=b>b</i>");
    assert.deepEqual(nodes("i").map((n) => n.id), ["n", "b"]);
    assert.equal(document.getElementById("b"), b);
  });

  it("matches unkeyed nodes by position", () => {
    page.innerHTML = "<p>a</p><p>b</p>";
    const [p1] = nodes("p");
    patch("<p>x</p><p>y</p><p>z</p>");
    assert.equal(nodes("p")[0], p1);
    assert.deepEqual(nodes("p").map((n) => n.textContent), ["x", "y", "z"]);
  });

  it("keeps a live child component where the parent only sends a slot", () => {
    page.innerHTML = '<div data-spark-id="k"><b>live</b></div><p>old</p>';
    const k = page.firstChild;
    patch('<p>new</p><section><div data-spark-id="k" data-spark-slot></div></section>');
    assert.equal(page.querySelector("section").firstChild, k, "the live element moved into the new wrapper");
    assert.equal(k.textContent, "live");
  });
});

describe("attributes and form state", () => {
  it("syncs attributes, boolean attributes and data-*", () => {
    page.innerHTML = '<button class="a" disabled data-x="1" hidden>go</button>';
    const button = page.firstChild;
    patch('<button class="b" data-y="2">go</button>');
    assert.equal(page.firstChild, button);
    assert.equal(button.className, "b");
    assert.equal(button.hasAttribute("disabled"), false);
    assert.equal(button.hasAttribute("hidden"), false);
    assert.equal(button.hasAttribute("data-x"), false);
    assert.equal(button.getAttribute("data-y"), "2");
  });

  it("keeps what the user typed when the server did not change the value", () => {
    page.innerHTML = '<input id="i" value="a">';
    const input = page.firstChild;
    input.value = "typed";
    patch('<input id="i" value="a">');
    assert.equal(input.value, "typed");
  });

  it("applies a value the server changed (control not focused)", () => {
    page.innerHTML = '<input id="i" value="a">';
    const input = page.firstChild;
    input.value = "typed";
    patch('<input id="i" value="b">');
    assert.equal(input.value, "b");
    assert.equal(input.getAttribute("value"), "b");
  });

  it("keeps what the user is typing in the focused control, and applies the server value after blur", () => {
    page.innerHTML = '<input id="i" value="a">';
    const input = page.firstChild;
    input.focus();
    input.value = "typed more";
    patch('<input id="i" value="b">');
    assert.equal(input.value, "typed more");
    assert.equal(document.activeElement, input);
    input.blur();
    patch('<input id="i" value="b">');
    assert.equal(input.value, "b");
  });

  it("does not touch a control during IME composition", () => {
    page.innerHTML = '<input id="i" value="a">';
    const input = page.firstChild;
    input.dispatchEvent(new window.Event("compositionstart", { bubbles: true }));
    input.value = "かな";
    patch('<input id="i" value="b">');
    assert.equal(input.value, "かな");
    input.dispatchEvent(new window.Event("compositionend", { bubbles: true }));
    patch('<input id="i" value="b">');
    assert.equal(input.value, "b");
  });

  it("checked follows the server only when the server changed it", () => {
    page.innerHTML = '<input type="checkbox" id="c1"><input type="checkbox" id="c2" checked>';
    const [one, two] = nodes("input");
    one.checked = true;
    two.checked = false;
    patch('<input type="checkbox" id="c1"><input type="checkbox" id="c2" checked>');
    assert.equal(one.checked, true);
    assert.equal(two.checked, false);
    patch('<input type="checkbox" id="c1" checked><input type="checkbox" id="c2">');
    assert.equal(one.checked, true);
    assert.equal(two.checked, false);
    patch('<input type="checkbox" id="c1"><input type="checkbox" id="c2" checked>');
    assert.equal(one.checked, false);
    assert.equal(two.checked, true);
  });

  it("selected options and textareas follow the same rule", () => {
    page.innerHTML = '<select id="s"><option value="1" selected>1</option><option value="2">2</option></select><textarea id="t">a</textarea>';
    const select = page.querySelector("select");
    const area = page.querySelector("textarea");
    select.value = "2";
    area.value = "mine";
    patch('<select id="s"><option value="1" selected>1</option><option value="2">2</option></select><textarea id="t">a</textarea>');
    assert.equal(select.value, "2");
    assert.equal(area.value, "mine");
    patch('<select id="s"><option value="1">1</option><option value="2" selected>2</option></select><textarea id="t">server</textarea>');
    assert.equal(select.value, "2");
    assert.equal(area.value, "server");
  });

  it("leaves the value alone for spark-ignore subtrees", () => {
    page.innerHTML = '<div spark-ignore id="w"><p>mine</p></div>';
    patch('<div spark-ignore id="w"><p>theirs</p></div>');
    assert.equal(page.textContent, "mine");
  });
});

describe("details and dialog", () => {
  it("keeps <details> the user opened until the server changes it", () => {
    page.innerHTML = "<details id=d><summary>s</summary>x</details>";
    const details = page.firstChild;
    details.open = true;
    details.dispatchEvent(new window.Event("toggle"));
    patch("<details id=d><summary>s</summary>y</details>");
    assert.equal(details.open, true, "the user's choice survives");
    assert.equal(details.textContent, "sy");
    patch("<details id=d open><summary>s</summary>y</details>"); // the server's first word on it
    assert.equal(details.open, true);
    patch("<details id=d><summary>s</summary>y</details>"); // the server changed its mind
    assert.equal(details.open, false);
  });

  it("keeps an open <dialog> open when the patch does not mention it", () => {
    page.innerHTML = "<dialog id=g>hi</dialog>";
    const dialog = page.firstChild;
    dialog.setAttribute("open", "");
    dialog.dispatchEvent(new window.Event("toggle"));
    patch("<dialog id=g>hello</dialog>");
    assert.equal(dialog.hasAttribute("open"), true);
    assert.equal(dialog.textContent, "hello");
  });
});

describe("focus, selection and scroll", () => {
  it("keeps focus and caret when the focused control sits in a moved subtree", () => {
    page.innerHTML = '<div id="a"><input id="i" value="hello"></div><div id="b">b</div>';
    const input = document.getElementById("i");
    input.focus();
    input.setSelectionRange(2, 4);
    patch('<div id="b">b</div><div id="a"><input id="i" value="hello"></div>');
    assert.equal(document.activeElement, input);
    assert.equal(input.selectionStart, 2);
    assert.equal(input.selectionEnd, 4);
  });

  it("restores focus and caret after the engine had to move the control", () => {
    page.innerHTML = '<input id="i" value="hello"><i id="x"></i><i id="y"></i>';
    const input = document.getElementById("i");
    input.focus();
    input.setSelectionRange(1, 3);
    const insert = window.Element.prototype.insertBefore;
    page.insertBefore = function (node, ref) { // a move blurs the control, as in a browser
      if (node === input) input.blur();
      return insert.call(this, node, ref);
    };
    patch('<i id="x"></i><i id="y"></i><input id="i" value="hello">');
    assert.equal(document.activeElement, input);
    assert.equal(input.selectionStart, 1);
    assert.equal(input.selectionEnd, 3);
  });

  it("restores the scroll offset of an element the engine had to move", () => {
    page.innerHTML = '<div id="s" style="overflow:auto"></div><i id="x"></i><i id="y"></i>';
    const box = document.getElementById("s");
    box.scrollTop = 40;
    const insert = window.Element.prototype.insertBefore;
    page.insertBefore = function (node, ref) {
      if (node === box) box.scrollTop = 0;
      return insert.call(this, node, ref);
    };
    patch('<i id="x"></i><i id="y"></i><div id="s" style="overflow:auto"></div>');
    assert.equal(box.scrollTop, 40);
  });

  it("does not replace the media element or rewrite its attributes", () => {
    page.innerHTML = '<video id="v" src="/a.mp4" controls></video><p>t</p>';
    const video = page.firstChild;
    let writes = 0;
    const set = video.setAttribute;
    video.setAttribute = function (...args) { writes++; return set.apply(this, args); };
    patch('<video id="v" src="/a.mp4" controls></video><p>t2</p>');
    assert.equal(page.firstChild, video);
    assert.equal(writes, 0);
  });
});

describe("frames", () => {
  it("applies every patch of a diff in one flush, in order, and emits events afterwards", () => {
    page.innerHTML = "<p>0</p>";
    const seen = [];
    page.addEventListener("spark:hit", () => seen.push(page.textContent));
    spark.applyDiff({ patches: [{ id: "c", html: "<p>1</p>" }, { id: "c", html: "<p>2</p>" }], events: [{ target: "c", name: "hit", payload: {} }] });
    assert.equal(page.textContent, "0", "nothing is written before the frame");
    spark.flushPatches();
    assert.equal(page.textContent, "2");
    assert.deepEqual(seen, ["2"]);
  });

  it("schedules one animation frame for a burst of diffs", () => {
    const frames = [];
    const raf = window.requestAnimationFrame;
    window.requestAnimationFrame = (fn) => frames.push(fn) && frames.length;
    try {
      spark.applyDiff({ patches: [{ id: "c", html: "a" }] });
      spark.applyDiff({ patches: [{ id: "c", html: "b" }] });
      assert.equal(frames.length, 1);
      frames[0]();
      assert.equal(page.textContent, "b");
    } finally { window.requestAnimationFrame = raf; }
  });

  it("reads before it writes: layout is queried once, ahead of every mutation", () => {
    page.innerHTML = "<p>a</p><p>b</p>";
    const log = [];
    const proto = window.Element.prototype;
    const scroll = Object.getOwnPropertyDescriptor(proto, "scrollTop");
    if (!scroll) return; // happy-dom without the accessor: nothing to observe
    Object.defineProperty(page.children[0], "scrollTop", { get() { log.push("read"); return 0; }, configurable: true });
    const set = page.children[0].firstChild;
    Object.defineProperty(set, "nodeValue", { set() { log.push("write"); }, get() { return "a"; }, configurable: true });
    patch("<p>x</p><p>y</p>");
    if (log.includes("write")) assert.ok(log.indexOf("read") < log.indexOf("write"));
  });
});

describe("scripts", () => {
  it("drops script elements, handlers and script URLs from a patch", () => {
    patch('<p onclick="x()">hi</p><script>window.__ran = 1</script><a href="javascript:x()">a</a>');
    assert.equal(window.__ran, undefined);
    assert.equal(page.querySelector("script"), null);
    assert.equal(page.querySelector("p").hasAttribute("onclick"), false);
    assert.equal(page.querySelector("a").hasAttribute("href"), false);
  });

  it("keeps inline scripts, rebuilt so they can run, only where the root opted in", () => {
    page.setAttribute("data-spark-allow-scripts", "");
    patch("<script>window.__ran = 1</script><iframe src=x></iframe>");
    const script = page.querySelector("script");
    assert.ok(script, "the opted-in root keeps its script");
    assert.equal(script.textContent, "window.__ran = 1");
    assert.equal(page.querySelector("iframe"), null, "everything else stays blocked");
    page.removeAttribute("data-spark-allow-scripts");
  });
});

describe("Trusted Types", () => {
  function mockTypes(log, { throwOnCreate = false } = {}) {
    window.trustedTypes = {
      createPolicy(name, rules) {
        log.push({ create: name, rules: Object.keys(rules) });
        if (throwOnCreate) throw new TypeError("policy not allowed");
        return { createHTML: (s) => { log.push({ html: s }); return { toString: () => s, trusted: true }; } };
      },
    };
  }

  it("parses through the named policy azu-spark, which can only create HTML", () => {
    const log = [];
    mockTypes(log);
    patch("<p>x</p>");
    assert.deepEqual(log.filter((e) => e.create), [{ create: "azu-spark", rules: ["createHTML"] }]);
    assert.ok(log.some((e) => e.html && e.html.includes("<p>x</p>")));
    assert.equal(page.textContent, "x");
    patch("<p>y</p>");
    assert.equal(log.filter((e) => e.create).length, 1, "the policy is created once");
  });

  it("falls back to plain strings when the page's CSP does not list the policy", () => {
    const log = [];
    mockTypes(log, { throwOnCreate: true });
    patch("<p>z</p>");
    assert.equal(page.textContent, "z");
  });

  it("never uses innerHTML on live nodes to patch", () => {
    const descriptor = Object.getOwnPropertyDescriptor(window.Element.prototype, "innerHTML");
    if (!descriptor || !descriptor.set) return;
    let used = 0;
    Object.defineProperty(window.Element.prototype, "innerHTML", { ...descriptor, set(v) { used++; return descriptor.set.call(this, v); } });
    try { patch("<p>q</p>"); } finally { Object.defineProperty(window.Element.prototype, "innerHTML", descriptor); }
    assert.equal(used, 0);
  });
});

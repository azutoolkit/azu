// Browser test of the Spark patch engine: what a patch must not disturb (focus, caret, an IME
// composition, a half typed value, scroll offsets), keyed moves, scripts, and Trusted Types.
//
//   spec/browser/run.sh          # see there for the requirements
//
// Part one drives playground/spark_demo/app.cr with two tabs: one types, the other chats, and the
// server patches the first tab while the user is in the middle of something. Part two serves pages
// whose WebSocket is scripted by the test, so exact diffs can be delivered, with and without a
// Content-Security-Policy that enforces Trusted Types. Missing playwright or chromium means SKIP
// (exit 0), unless SPARK_BROWSER_REQUIRED=1.
const net = require("net");
const http = require("http");
const assert = require("assert");
const { spawn } = require("child_process");

let APP_PORT;
let URL_;
const REQUIRED = process.env.SPARK_BROWSER_REQUIRED === "1";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function skip(reason) {
  console.log(`SKIP spark patch browser test: ${reason}`);
  process.exit(REQUIRED ? 1 : 0);
}

function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer().on("error", reject);
    probe.listen(0, "127.0.0.1", () => { const { port } = probe.address(); probe.close(() => resolve(port)); });
  });
}

function loadPlaywright() {
  for (const name of [process.env.PLAYWRIGHT_MODULE, "playwright", "playwright-core"].filter(Boolean)) {
    try { return require(name); } catch (e) { /* try the next */ }
  }
  return skip("playwright is not installed (npm i playwright, or set PLAYWRIGHT_MODULE)");
}

function startApp() {
  const command = process.env.SPARK_SERVER_CMD || "crystal run playground/spark_demo/app.cr";
  return spawn("sh", ["-c", command], {
    env: { ...process.env, PORT: String(APP_PORT), HOST: "127.0.0.1", SPARK_HEARTBEAT_INTERVAL: "5" },
    stdio: ["ignore", "inherit", "inherit"],
    detached: true,
  });
}

function ready(deadline) {
  return new Promise((resolve, reject) => {
    const attempt = () => {
      http.get(`${URL_}`, (res) => { res.resume(); resolve(); })
        .on("error", () => (Date.now() > deadline ? reject(new Error("app did not start")) : setTimeout(attempt, 500)));
    };
    attempt();
  });
}

function fetchText(url) {
  return new Promise((resolve, reject) => http.get(url, (res) => {
    let body = "";
    res.on("data", (chunk) => (body += chunk)).on("end", () => resolve(body));
  }).on("error", reject));
}

// ---- part one: the demo app ---------------------------------------------------------------

async function demo(browser) {
  const open = async () => {
    const page = await (await browser.newContext()).newPage();
    page.on("pageerror", (error) => { throw error; });
    await page.goto(URL_);
    await page.waitForSelector("html[data-spark-status=connected]", { timeout: 20000 });
    return page;
  };
  const reader = await open();
  const writer = await open();
  let serial = 0;
  // The writer chats; the reader receives a patch of its chat component.
  const say = async (text) => {
    await writer.fill("#text", text);
    await writer.press("#text", "Enter");
    await reader.waitForFunction((t) => [...document.querySelectorAll("#lines li")].some((li) => li.textContent.endsWith(t)), text, { timeout: 10000 });
  };
  const next = () => `m${++serial}`;

  // 1. A half typed value in a control that lost focus is not erased by a patch.
  await reader.fill("#text", "my draft");
  await reader.evaluate(() => { window.__input = document.querySelector("#text"); document.querySelector("h1").tabIndex = -1; document.querySelector("h1").focus(); });
  await say(next());
  assert.deepStrictEqual(await reader.evaluate(() => ({ value: document.querySelector("#text").value, same: document.querySelector("#text") === window.__input })), { value: "my draft", same: true });
  console.log("ok   an unfocused, half typed value survives a patch");

  // 2. Focus and caret stay where the user put them while a patch lands.
  await reader.fill("#text", "hello brave world");
  await reader.evaluate(() => { const i = document.querySelector("#text"); i.focus(); i.setSelectionRange(6, 11); });
  await say(next());
  assert.deepStrictEqual(
    await reader.evaluate(() => { const i = document.querySelector("#text"); return { focused: document.activeElement === i, same: i === window.__input, start: i.selectionStart, end: i.selectionEnd, value: i.value }; }),
    { focused: true, same: true, start: 6, end: 11, value: "hello brave world" },
  );
  await reader.keyboard.type("X"); // typing continues where it was
  assert.strictEqual(await reader.inputValue("#text"), "hello X world");
  console.log("ok   focus, caret and selection survive a patch");

  // 3. An IME composition is not interrupted: the composing text stays and no compositionend fires.
  await reader.fill("#text", "");
  await reader.evaluate(() => {
    window.__composition = [];
    for (const name of ["compositionstart", "compositionupdate", "compositionend"]) document.querySelector("#text").addEventListener(name, (e) => window.__composition.push(e.type));
    document.querySelector("#text").focus();
  });
  const cdp = await reader.context().newCDPSession(reader);
  await cdp.send("Input.imeSetComposition", { text: "かな", selectionStart: 2, selectionEnd: 2 });
  await say(next());
  assert.deepStrictEqual(
    await reader.evaluate(() => ({ value: document.querySelector("#text").value, same: document.querySelector("#text") === window.__input, events: window.__composition })),
    { value: "かな", same: true, events: ["compositionstart", "compositionupdate"] },
    "the composition is still open after the patch",
  );
  await cdp.send("Input.insertText", { text: "仮名" });
  assert.strictEqual(await reader.inputValue("#text"), "仮名");
  console.log("ok   an IME composition survives a patch");

  // 4. A scrolled list keeps its offset while lines are added.
  for (let i = 0; i < 8; i++) await say(next());
  const before = await reader.evaluate(() => { const ul = document.querySelector("#lines"); ul.scrollTop = 25; return { top: ul.scrollTop, scrollable: ul.scrollHeight > ul.clientHeight }; });
  assert(before.scrollable && before.top === 25, `the list must be scrollable for this test (${JSON.stringify(before)})`);
  await say(next());
  await say(next());
  assert.strictEqual(await reader.evaluate(() => document.querySelector("#lines").scrollTop), 25, "the scroll offset moved");
  console.log("ok   scroll position survives a patch");
  await reader.context().close();
  await writer.context().close();
}

// ---- part two: scripted pages --------------------------------------------------------------

const ROOT = (attrs, inner) => `<div data-spark-root data-spark-id="r" data-spark-token="t" ${attrs}><div data-spark-id="r~c">${inner}</div></div><script src="/azu_spark.js"></script>`;

async function scripted(browser, { body, headers = {}, moveBefore = true }) {
  const script = await fetchText(`${URL_}_spark/azu_spark.js`);
  const page = await (await browser.newContext()).newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.route("http://test.local/", (route) => route.fulfill({ contentType: "text/html", headers, body }));
  await page.route("http://test.local/azu_spark.js", (route) => route.fulfill({ contentType: "text/javascript", body: script }));
  await page.addInitScript((keepMove) => {
    if (!keepMove) delete Element.prototype.moveBefore;
    window.__violations = [];
    document.addEventListener("securitypolicyviolation", (e) => window.__violations.push(e.violatedDirective));
    window.FakeWS = class {
      constructor() { this.readyState = 1; window.__ws = this; }
      send(text) { window.__last = JSON.parse(text); }
      close() {}
    };
    Object.assign(FakeWS, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
    window.WebSocket = FakeWS;
    window.__frame = (frame) => window.__ws.onmessage({ data: JSON.stringify({ v: 1, ...frame }) });
    window.__errors = [];
    document.addEventListener("spark:error", (e) => window.__errors.push(e.detail));
  }, moveBefore);
  await page.goto("http://test.local/");
  await page.waitForFunction(() => window.__ws);
  await page.evaluate(() => window.__frame({ type: "hello", heartbeat: 20000, max_size: 65536 }));
  await page.evaluate(() => window.__frame({ type: "reply", id: window.__last.id }));
  const patch = (html) => page.evaluate((h) => window.__frame({ type: "diff", seq: 1, patches: [{ id: "r~c", html: h }], events: [], snapshots: {} }), html);
  const applied = () => page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  return { page, patch, applied, errors };
}

const BOXES = (first) => {
  const a = `<section id="a"><div id="box" style="overflow:auto;height:50px;width:100px"><div style="height:600px">tall</div></div><input id="f" value="0123456789"></section>`;
  const b = `<section id="b">b</section>`;
  return first ? a + b : b + a;
};

async function moved(browser, moveBefore) {
  const { page, patch, applied, errors } = await scripted(browser, { body: ROOT("", BOXES(true)), moveBefore });
  const name = moveBefore ? "moveBefore" : "insertBefore";
  await page.evaluate(() => {
    document.getElementById("box").scrollTop = 120;
    const f = document.getElementById("f");
    f.focus();
    f.setSelectionRange(2, 5);
    window.__box = document.getElementById("box");
    window.__f = f;
  });
  await patch(BOXES(false));
  await applied();
  const state = await page.evaluate(() => ({
    order: [...document.querySelectorAll("section")].map((s) => s.id),
    sameBox: document.getElementById("box") === window.__box,
    sameInput: document.getElementById("f") === window.__f,
    scroll: document.getElementById("box").scrollTop,
    focused: document.activeElement === document.getElementById("f"),
    caret: [document.getElementById("f").selectionStart, document.getElementById("f").selectionEnd],
  }));
  assert.deepStrictEqual(state, { order: ["b", "a"], sameBox: true, sameInput: true, scroll: 120, focused: true, caret: [2, 5] }, `${name}: ${JSON.stringify(state)}`);
  assert.deepStrictEqual(errors, []);
  console.log(`ok   a keyed move keeps focus, caret and scroll (${name})`);
  await page.close();
}

async function scripts(browser) {
  for (const optIn of [false, true]) {
    const { page, patch, applied } = await scripted(browser, { body: ROOT(optIn ? "data-spark-allow-scripts" : "", "<p>x</p>") });
    await patch("<p>y</p><script>window.__ran = (window.__ran || 0) + 1</script><img src=x onerror=\"window.__ran = 99\">");
    await applied();
    assert.strictEqual(await page.evaluate(() => document.querySelector("img").hasAttribute("onerror")), false);
    await patch("<p>z</p><script>window.__ran = (window.__ran || 0) + 1</script>");
    await applied();
    const ran = await page.evaluate(() => window.__ran);
    assert.strictEqual(ran, optIn ? 1 : undefined, optIn ? "an opted-in root runs a new script once, an unchanged one is not run again" : "a patch script never runs");
    await page.close();
  }
  console.log("ok   scripts in patches run only for a root that opted in");
}

const CSP = (policy) => `script-src 'self'; ${policy}`;

async function trustedTypes(browser) {
  const body = ROOT("", "<p>x</p>");
  let { page, patch, applied, errors } = await scripted(browser, { body, headers: { "content-security-policy": CSP("require-trusted-types-for 'script'; trusted-types azu-spark") } });
  await patch("<p>patched <b>under</b> trusted types</p><script>window.__ran = 1</script>");
  await applied();
  assert.strictEqual(await page.evaluate(() => document.querySelector("[data-spark-id='r~c']").textContent), "patched under trusted types");
  assert.deepStrictEqual(await page.evaluate(() => window.__violations), [], "no CSP violation");
  assert.deepStrictEqual(await page.evaluate(() => window.__errors), []);
  assert.deepStrictEqual(errors, []);
  assert.strictEqual(await page.evaluate(() => window.__ran), undefined);
  await page.close();

  // The policy is not listed: the patch cannot be parsed. It is reported, never run unsafely.
  ({ page, patch, applied, errors } = await scripted(browser, { body, headers: { "content-security-policy": CSP("require-trusted-types-for 'script'; trusted-types somebody-else") } }));
  await patch("<p>never</p>");
  await applied();
  assert.strictEqual(await page.evaluate(() => document.querySelector("[data-spark-id='r~c']").textContent), "x");
  assert.strictEqual((await page.evaluate(() => window.__errors))[0].code, "patch_failed");
  await page.close();
  console.log("ok   patches work under require-trusted-types-for with the azu-spark policy, and fail closed without it");
}

async function main() {
  const { chromium } = loadPlaywright();
  APP_PORT = Number(process.env.BROWSER_TEST_PORT) || (await freePort());
  URL_ = `http://127.0.0.1:${APP_PORT}/`;
  const app = startApp();
  let browser;
  try {
    await ready(Date.now() + 300000);
    try {
      browser = await chromium.launch({ args: ["--no-sandbox"], executablePath: process.env.CHROMIUM_PATH || undefined });
    } catch (e) { return skip(`chromium cannot start (${e.message.split("\n")[0]})`); }
    await demo(browser);
    await moved(browser, true);
    await moved(browser, false);
    await scripts(browser);
    await trustedTypes(browser);
    console.log("spark patch browser test passed");
  } finally {
    if (browser) await browser.close().catch(() => {});
    try { process.kill(-app.pid, "SIGTERM"); } catch (e) { /* already gone */ }
  }
}

main().then(() => process.exit(0), (error) => { console.error(error); process.exit(1); });

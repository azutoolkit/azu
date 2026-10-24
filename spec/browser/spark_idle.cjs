// Browser test of the hidden-tab idle close, the live region and aria-busy of the Spark client.
//
//   spec/browser/run.sh          # see there for the requirements
//
// Part one drives playground/spark_demo/app.cr with a page whose script tag got a short
// data-spark-hidden-idle: a tab that is "hidden" (document.visibilityState is overridden, as
// headless Chromium has no hidden tabs) closes its socket with code 1000, keeps its state and
// rejoins when it returns, and delivers an event made while it idled. Part two serves a scripted
// page under a strict Content-Security-Policy (default-src 'none'; no inline styles) and checks
// that exactly one polite live region exists and is visually hidden, aria-busy is set only after
// 150 ms, and focus never moves. Missing playwright or chromium means SKIP (exit 0), unless
// SPARK_BROWSER_REQUIRED=1.
const net = require("net");
const http = require("http");
const assert = require("assert");
const { spawn } = require("child_process");

let APP_PORT;
let URL_;
const REQUIRED = process.env.SPARK_BROWSER_REQUIRED === "1";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const IDLE_MS = 1500;

function skip(reason) {
  console.log(`SKIP spark idle browser test: ${reason}`);
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
    env: { ...process.env, PORT: String(APP_PORT), HOST: "127.0.0.1", SPARK_HEARTBEAT_INTERVAL: "1" },
    stdio: ["ignore", "inherit", "inherit"],
    detached: true,
  });
}

function ready(deadline) {
  return new Promise((resolve, reject) => {
    const attempt = () => {
      http.get(URL_, (res) => { res.resume(); resolve(); })
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

const visibility = (page, state) => page.evaluate((value) => {
  Object.defineProperty(document, "visibilityState", { value, configurable: true });
  Object.defineProperty(document, "hidden", { value: value === "hidden", configurable: true });
  document.dispatchEvent(new Event("visibilitychange"));
}, state);

// ---- part one: the real server -----------------------------------------------------------

async function demoPage(browser) {
  const page = await (await browser.newContext()).newPage();
  page.on("pageerror", (error) => { throw error; });
  // The server renders the script tag; give it the short window.
  await page.route(URL_, async (route) => {
    const response = await route.fetch();
    const body = (await response.text()).replace("data-spark-path=", `data-spark-hidden-idle="${IDLE_MS}" data-spark-path=`);
    await route.fulfill({ response, body });
  });
  await page.addInitScript(() => {
    window.__sockets = [];
    const Native = window.WebSocket;
    window.WebSocket = class extends Native {
      constructor(...args) {
        super(...args);
        const entry = { events: [], closed: null };
        window.__sockets.push(entry);
        const send = this.send.bind(this);
        this.send = (data) => {
          const frame = JSON.parse(data);
          if (frame.type === "event") entry.events.push(frame.event);
          return send(data);
        };
        const close = this.close.bind(this);
        this.close = (code, reason) => { entry.requested = { code, reason }; return close(code, reason); };
        this.addEventListener("close", (e) => { entry.closed = { code: e.code, reason: e.reason, wasClean: e.wasClean }; });
      }
    };
  });
  await page.goto(URL_);
  await page.waitForSelector("html[data-spark-status=connected]", { timeout: 20000 });
  return page;
}

const count = async (page) => Number((await page.textContent("#count")).replace("Clicks: ", ""));

async function idleClose(browser) {
  const page = await demoPage(browser);
  const n = await count(page);
  await page.click("#inc");
  await page.waitForFunction((v) => document.querySelector("#count").textContent === `Clicks: ${v + 1}`, n, { timeout: 15000 });
  await sleep(500); // let the snapshot arrive with the diff

  // Hidden, but back inside the window: nothing happens. The heartbeat (1 s) keeps going.
  await visibility(page, "hidden");
  await sleep(IDLE_MS / 2);
  await visibility(page, "visible");
  await sleep(IDLE_MS);
  let sockets = await page.evaluate(() => window.__sockets.length);
  assert.strictEqual(sockets, 1, "a short absence does not touch the connection");
  assert.strictEqual(await page.evaluate(() => AzuSpark.stats().state), "open");

  // Hidden for the whole window: a clean close with 1000, no new socket while it idles.
  await visibility(page, "hidden");
  await page.waitForFunction(() => AzuSpark.stats().state === "hidden-idle", null, { timeout: IDLE_MS + 6000 });
  // What the client asked for (the browser reports the server's echo, which carries no status: 1005).
  const { requested, closed } = await page.evaluate(() => window.__sockets[0]);
  assert.deepStrictEqual(requested, { code: 1000, reason: "hidden idle" });
  assert.strictEqual(closed.wasClean, true);
  await sleep(2500);
  assert.strictEqual(await page.evaluate(() => window.__sockets.length), 1, "no reconnect while hidden: nothing flaps");
  assert.strictEqual(await page.evaluate(() => document.documentElement.dataset.sparkStatus), "disconnected");

  // Back: it rejoins from the snapshot, so the state survived.
  await visibility(page, "visible");
  await page.waitForFunction(() => document.documentElement.dataset.sparkStatus === "connected" && window.__sockets.length === 2, null, { timeout: 15000 });
  assert.strictEqual(await count(page), n + 1, "the state survived the idle close");
  await page.click("#inc");
  await page.waitForFunction((v) => document.querySelector("#count").textContent === `Clicks: ${v + 2}`, n, { timeout: 15000 });
  console.log("ok   a tab hidden for the window closes with 1000, then rejoins from its snapshot with its state");

  // An event made while the tab idles wakes the connection and is delivered exactly once.
  await visibility(page, "hidden");
  await page.waitForFunction(() => AzuSpark.stats().state === "hidden-idle", null, { timeout: IDLE_MS + 6000 });
  await page.evaluate(() => AzuSpark.push(document.querySelector("#inc"), "increment", {}));
  await page.waitForFunction((v) => document.querySelector("#count").textContent === `Clicks: ${v + 3}`, n, { timeout: 15000 });
  await sleep(1000);
  assert.strictEqual(await count(page), n + 3, "applied once");
  assert.strictEqual(await page.evaluate(() => AzuSpark.stats().queue.waiting + AzuSpark.stats().queue.unacked), 0);
  sockets = await page.evaluate(() => window.__sockets.length);
  assert.ok(sockets >= 3);
  console.log("ok   an event made by an idle tab wakes the connection and takes effect once");

  // The offline state is announced through the one live region.
  await visibility(page, "visible");
  await page.waitForFunction(() => document.documentElement.dataset.sparkStatus === "connected", null, { timeout: 15000 });
  await page.context().setOffline(true);
  await page.evaluate(() => window.dispatchEvent(new Event("offline")));
  await page.waitForFunction(() => document.querySelector("[aria-live]") && document.querySelector("[aria-live]").textContent.startsWith("Offline"), null, { timeout: 5000 });
  assert.strictEqual(await page.evaluate(() => document.querySelectorAll("[aria-live]").length), 1, "exactly one live region");
  await page.context().setOffline(false);
  await page.close();
  console.log("ok   offline is announced in the live region");
}

// ---- part two: a page under a strict CSP --------------------------------------------------

async function strictPage(browser) {
  const page = await (await browser.newContext()).newPage();
  const script = await fetchText(`${URL_}_spark/azu_spark.js`);
  await page.route("http://test.local/", (route) => route.fulfill({
    contentType: "text/html",
    headers: { "content-security-policy": "default-src 'none'; script-src 'self'; connect-src 'self'" },
    body: `<div id="root" data-spark-root data-spark-id="r" data-spark-token="t"><div data-spark-id="r~c">
      <button id="go" spark-click="go">go</button><input id="a"></div></div><script src="/azu_spark.js"></script>`,
  }));
  await page.route("http://test.local/azu_spark.js", (route) => route.fulfill({ contentType: "text/javascript", body: script }));
  await page.addInitScript(() => {
    window.__violations = [];
    document.addEventListener("securitypolicyviolation", (e) => window.__violations.push(e.violatedDirective));
    window.__sent = [];
    window.FakeWS = class {
      constructor() { this.readyState = 1; window.__ws = this; window.__made = (window.__made || 0) + 1; }
      send(text) { window.__sent.push(JSON.parse(text)); }
      close(code, reason) { this.readyState = 3; window.__closedWith = { code, reason }; }
    };
    Object.assign(FakeWS, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
    window.WebSocket = FakeWS;
    window.__frame = (frame) => window.__ws.onmessage({ data: JSON.stringify({ v: 1, ...frame }) });
  });
  await page.goto("http://test.local/");
  await page.waitForFunction(() => window.__ws);
  const frame = (f) => page.evaluate((x) => window.__frame(x), f);
  await frame({ type: "hello", heartbeat: 20000, max_size: 65536 });
  const join = await page.evaluate(() => window.__sent.filter((m) => m.type === "join").pop());
  await frame({ type: "reply", id: join.id });
  assert.strictEqual(await page.evaluate(() => document.querySelectorAll("[aria-live]").length), 0, "no region before something is announced");

  // aria-busy: absent for a quick answer, present for a slow one, gone with the answer.
  await page.focus("#a");
  await page.click("#go", { noWaitAfter: true });
  const sent = () => page.evaluate(() => window.__sent.filter((m) => m.type === "event"));
  await sleep(50);
  assert.strictEqual(await page.getAttribute("#root", "aria-busy"), null, "not busy within 150 ms");
  let [event] = await sent();
  await frame({ type: "reply", id: event.id, target: event.target });
  await sleep(300);
  assert.strictEqual(await page.getAttribute("#root", "aria-busy"), null, "a quick answer never flickers");
  await page.click("#go");
  event = (await sent())[1];
  await page.waitForFunction(() => document.getElementById("root").getAttribute("aria-busy") === "true", null, { timeout: 2000 });
  await frame({ type: "reply", id: event.id, target: event.target });
  await page.waitForFunction(() => !document.getElementById("root").hasAttribute("aria-busy"), null, { timeout: 2000 });
  console.log("ok   aria-busy appears for an event unanswered after 150 ms, and not for a quick one");

  await page.focus("#a");
  // A lost connection is announced once, in one region that styles itself without a style attribute.
  await page.evaluate(() => window.__ws.onclose({ code: 1006, reason: "lost" }));
  await page.waitForFunction(() => document.querySelector("[aria-live]") && document.querySelector("[aria-live]").textContent === "Reconnecting...", null, { timeout: 4000 });
  const region = await page.evaluate(() => {
    const el = document.querySelector("[aria-live]");
    const box = getComputedStyle(el);
    return {
      count: document.querySelectorAll("[aria-live]").length, role: el.getAttribute("role"), live: el.getAttribute("aria-live"),
      width: box.width, height: box.height, position: box.position, overflow: box.overflow,
      rect: el.getBoundingClientRect().width, active: document.activeElement && document.activeElement.id,
    };
  });
  assert.deepStrictEqual({ ...region, active: undefined }, {
    count: 1, role: "status", live: "polite", width: "1px", height: "1px", position: "absolute", overflow: "hidden", rect: 1, active: undefined,
  });
  assert.strictEqual(region.active, "a", "focus was not moved");
  assert.deepStrictEqual(await page.evaluate(() => window.__violations), [], "no CSP violation");
  await page.waitForFunction(() => window.__made === 2, null, { timeout: 5000 });
  await frame({ type: "hello", heartbeat: 20000, max_size: 65536 });
  const joins = await page.evaluate(() => window.__sent.filter((m) => m.type === "join"));
  await frame({ type: "reply", id: joins[1].id });
  await page.waitForFunction(() => document.querySelector("[aria-live]").textContent === "Back online.", null, { timeout: 2000 });
  assert.strictEqual(await page.evaluate(() => document.querySelectorAll("[aria-live]").length), 1);
  await page.close();
  console.log("ok   one polite live region, visually hidden under a strict CSP, announces lost and restored");
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
    await idleClose(browser);
    await strictPage(browser);
    console.log("spark idle browser test passed");
  } finally {
    if (browser) await browser.close().catch(() => {});
    try { process.kill(-app.pid, "SIGKILL"); } catch (e) { /* gone */ }
  }
}

main().then(() => process.exit(0), (error) => { console.error("FAIL", error); process.exit(1); });

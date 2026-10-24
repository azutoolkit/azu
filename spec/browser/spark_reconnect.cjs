// Browser test of the Spark JavaScript client: reconnect with backoff, rehydration, the queue of
// events raised while offline, heartbeat detection of a half open connection and server restarts.
//
//   spec/browser/run.sh          # see there for the requirements
//
// A TCP proxy stands between the browser and playground/spark_demo/app.cr, so the test can sever
// connections, refuse new ones, swallow traffic (a half open connection) and send a "going away"
// close frame without restarting the app. Missing playwright or chromium means SKIP (exit 0),
// unless SPARK_BROWSER_REQUIRED=1.
const net = require("net");
const http = require("http");
const assert = require("assert");
const { spawn } = require("child_process");

// Free ports, chosen per run (BROWSER_TEST_PORT pins the app port, the proxy takes the next one). A fixed
// port was a trap: a server left behind by an earlier run (a container outlives the process that
// started it) keeps answering on it, ignores this run's SPARK_HEARTBEAT_INTERVAL, and the new app
// silently fails to bind.
let APP_PORT;
let PROXY_PORT;
let URL_;
const REQUIRED = process.env.SPARK_BROWSER_REQUIRED === "1";

function skip(reason) {
  console.log(`SKIP spark browser test: ${reason}`);
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

// ---- proxy ----------------------------------------------------------------------------

class Proxy {
  constructor() {
    this.sockets = new Set();
    this.refusing = false;
    this.blackhole = false;
    this.attempts = [];
    this.server = net.createServer((client) => this.accept(client));
  }

  listen() { return new Promise((resolve) => this.server.listen(PROXY_PORT, "127.0.0.1", resolve)); }

  accept(client) {
    if (this.refusing) {
      this.attempts.push(Date.now());
      return client.destroy();
    }
    const upstream = net.connect(APP_PORT, "127.0.0.1");
    this.sockets.add(client).add(upstream);
    const forward = (from, to) => from.on("data", (chunk) => { if (!this.blackhole) to.write(chunk); });
    forward(client, upstream);
    forward(upstream, client);
    const end = () => { client.destroy(); upstream.destroy(); this.sockets.delete(client); this.sockets.delete(upstream); };
    client.on("error", end).on("close", end);
    upstream.on("error", end).on("close", end);
    client.on("close", () => upstream.destroy());
  }

  sever() { this.sockets.forEach((socket) => socket.destroy()); this.sockets.clear(); }

  // An unmasked server close frame, as a restarting server would send, then the connection ends.
  goAway(code) {
    const frame = Buffer.from([0x88, 0x02, code >> 8, code & 255]);
    this.sockets.forEach((socket) => { if (socket.remotePort !== APP_PORT) socket.end(frame); });
    setTimeout(() => this.sever(), 500);
  }
}

// ---- app ------------------------------------------------------------------------------

function startApp() {
  const command = process.env.SPARK_SERVER_CMD || "crystal run playground/spark_demo/app.cr";
  const child = spawn("sh", ["-c", command], {
    env: { ...process.env, PORT: String(APP_PORT), HOST: "127.0.0.1", SPARK_HEARTBEAT_INTERVAL: "1" },
    stdio: ["ignore", "inherit", "inherit"],
    detached: true,
  });
  return child;
}

function ready(deadline) {
  return new Promise((resolve, reject) => {
    const attempt = () => {
      http.get(`http://127.0.0.1:${APP_PORT}/`, (res) => { res.resume(); resolve(); })
        .on("error", () => (Date.now() > deadline ? reject(new Error("app did not start")) : setTimeout(attempt, 500)));
    };
    attempt();
  });
}

// ---- scenarios ---

// A page with one Spark root whose WebSocket is scripted by the test: what the client sends, when,
// with no server involved.
async function scriptedPage(browser) {
  const page = await (await browser.newContext()).newPage();
  await page.route("http://test.local/", (route) => route.fulfill({
    contentType: "text/html",
    body: `<div data-spark-root data-spark-id="r" data-spark-token="t"><div data-spark-id="r~c">
      <input id="a" name="a" spark-change="field"><input id="b" name="b" spark-change="field"></div></div>
      <script src="/azu_spark.js"></script>`,
  }));
  const script = await new Promise((resolve, reject) => http.get(`${URL_}_spark/azu_spark.js`, (res) => {
    let body = "";
    res.on("data", (chunk) => (body += chunk)).on("end", () => resolve(body));
  }).on("error", reject));
  await page.route("http://test.local/azu_spark.js", (route) => route.fulfill({ contentType: "text/javascript", body: script }));
  await page.addInitScript(() => {
    window.__sent = [];
    window.FakeWS = class {
      constructor() { this.readyState = 1; window.__ws = this; window.__sockets = (window.__sockets || 0) + 1; }
      send(text) { window.__sent.push(JSON.parse(text)); }
      close(code, reason) { window.__closed = (window.__closed || []).concat({ code, reason }); }
    };
    Object.assign(FakeWS, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
    window.WebSocket = FakeWS;
    window.__frame = (frame) => window.__ws.onmessage({ data: JSON.stringify({ v: 1, ...frame }) });
  });
  await page.goto("http://test.local/");
  await page.waitForFunction(() => window.__ws);
  const sent = (type) => page.evaluate((t) => window.__sent.filter((m) => m.type === t), type);
  const frame = (f) => page.evaluate((x) => window.__frame(x), f);
  const open = async () => {
    await frame({ type: "hello", heartbeat: 20000, max_size: 65536 });
    const joins = await sent("join");
    await frame({ type: "reply", id: joins[joins.length - 1].id });
  };
  return { page, sent, frame, open };
}

async function scriptedSocket(browser) {
  const { page, sent, frame, open } = await scriptedPage(browser);
  await open();
  await frame({ type: "diff", seq: 1, patches: [], events: [], snapshots: { r: "token-1" } });

  // The connection is lost; two different inputs change while offline.
  await page.evaluate(() => window.__ws.onclose({ code: 1006 }));
  for (const [id, value] of [["a", "first"], ["b", "second"]]) {
    await page.fill(`#${id}`, value);
  }
  await page.fill("#a", "first again");
  assert.strictEqual(await page.evaluate(() => AzuSpark.queued), 2, "one queued event per control, the newer value replacing the older");

  // Reconnect: the server refuses the snapshot. Nothing may be sent before the page has rejoined.
  await page.waitForFunction(() => window.__sockets === 2, null, { timeout: 5000 });
  await frame({ type: "hello", heartbeat: 20000, max_size: 65536 });
  let joins = await sent("join");
  assert.strictEqual(joins.length, 2);
  assert.strictEqual(joins[1].snapshot, "token-1");
  assert.strictEqual((await sent("event")).length, 0, "no event ahead of the join");
  await frame({ type: "error", id: joins[1].id, code: "invalid_snapshot", message: "x" });
  joins = await sent("join");
  assert.strictEqual(joins.length, 3, "rejoins without the snapshot");
  assert.strictEqual(joins[2].snapshot, undefined);
  assert.strictEqual((await sent("event")).length, 0, "still no event while the rejoin is unanswered");
  await frame({ type: "reply", id: joins[2].id });
  const events = await sent("event");
  assert.deepStrictEqual(events.map((e) => e.payload.value).sort(), ["first again", "second"]);
  assert.strictEqual(events.length, 2, "both fields delivered, none lost");
  await page.close();
}

// A tab that becomes visible asks the server for a sign of life, and drops a connection that does
// not answer (the visibilitychange handler used to lose this probe to a comment).
async function visibilityProbe(browser) {
  const { page, sent, frame, open } = await scriptedPage(browser);
  await open();
  await page.waitForSelector("html[data-spark-status=connected]");
  assert.strictEqual((await sent("heartbeat")).length, 0, "no heartbeat yet: the server proposed 20 s");
  const show = () => page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true });
    document.dispatchEvent(new Event("visibilitychange"));
  });

  await show();
  assert.strictEqual((await sent("heartbeat")).length, 1, "becoming visible probes the connection");
  await frame({ type: "heartbeat", id: 1 });
  await sleep(3500);
  assert.strictEqual(await page.evaluate(() => document.documentElement.dataset.sparkStatus), "connected", "an answered probe keeps the connection");

  await show();
  assert.strictEqual((await sent("heartbeat")).length, 2);
  await page.waitForSelector("html:not([data-spark-status=connected])", { timeout: 5000 });
  const closed = await page.evaluate(() => window.__closed);
  assert.strictEqual(closed[0].reason, "heartbeat timeout", "an unanswered probe drops the connection");
  assert.strictEqual(closed[0].code, 4000);
  await page.waitForFunction(() => window.__sockets === 2, null, { timeout: 5000 });
  await page.close();
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const { chromium } = loadPlaywright();
  APP_PORT = Number(process.env.BROWSER_TEST_PORT) || (await freePort());
  PROXY_PORT = Number(process.env.BROWSER_TEST_PORT) ? APP_PORT + 1 : await freePort();
  URL_ = `http://127.0.0.1:${PROXY_PORT}/`;
  const app = startApp();
  const proxy = new Proxy();
  let browser;
  try {
    await ready(Date.now() + 300000);
    await proxy.listen();
    try {
      browser = await chromium.launch({ args: ["--no-sandbox"], executablePath: process.env.CHROMIUM_PATH || undefined });
    } catch (e) { return skip(`chromium cannot start (${e.message.split("\n")[0]})`); }

    const page = await (await browser.newContext()).newPage();
    page.on("pageerror", (error) => { throw error; });
    // Record the heartbeat interval the server proposes: the half open scenario depends on it.
    await page.addInitScript(() => {
      const Native = window.WebSocket;
      window.WebSocket = class extends Native {
        constructor(...args) {
          super(...args);
          this.addEventListener("message", (event) => {
            const frame = JSON.parse(event.data);
            if (frame.type === "hello") window.__heartbeat = frame.heartbeat;
          });
        }
      };
    });
    await page.goto(URL_);
    const connected = () => page.waitForSelector("html[data-spark-status=connected]", { timeout: 20000 });
    const count = () => page.textContent("#count");
    await page.evaluate(() => {
      window.__log = [];
      for (const name of ["open", "close", "reconnect", "error"]) AzuSpark.on(name, (detail) => window.__log.push({ name, ...detail }));
    });
    await connected();
    const heartbeat = await page.evaluate(() => window.__heartbeat);
    assert.strictEqual(heartbeat, 1000, `the server proposed a ${heartbeat} ms heartbeat, the test needs 1000: the command that starts the app must pass SPARK_HEARTBEAT_INTERVAL=1 to it (a docker wrapper has to forward the variable), and nothing else may be listening on its port`);
    await page.click("#inc10");
    await page.waitForFunction(() => document.querySelector("#count").textContent === "Clicks: 10");
    const log = (name) => page.evaluate((n) => window.__log.filter((entry) => entry.name === n), name);
    console.log("ok   connects and updates");

    // 1. The socket is cut and the server unreachable: backoff, queue, rehydrate, deliver once.
    proxy.refusing = true;
    proxy.sever();
    await page.waitForSelector("html:not([data-spark-status=connected])");
    await page.click("#inc");
    assert.strictEqual(await page.evaluate(() => AzuSpark.queued), 1, "the click waits in the queue");
    // Full jitter: each delay is random between 0 and a ceiling that doubles (500 ms, 1 s, 2 s ...) up to 15 s.
    for (const deadline = Date.now() + 25000; proxy.attempts.length < 4 && Date.now() < deadline;) await sleep(250);
    assert(proxy.attempts.length >= 4, `expected several reconnect attempts, got ${proxy.attempts.length}`);
    const delays = (await log("reconnect")).map((entry) => entry.delay);
    (await log("reconnect")).forEach((entry) => {
      const ceiling = Math.min(15000, 500 * 2 ** (entry.attempts - 1));
      assert(entry.delay >= 0 && entry.delay <= ceiling, `delay ${entry.delay} outside 0..${ceiling} for attempt ${entry.attempts}`);
    });
    proxy.refusing = false;
    await connected();
    await page.waitForFunction(() => document.querySelector("#count").textContent === "Clicks: 11", null, { timeout: 20000 });
    await sleep(1500);
    assert.strictEqual(await count(), "Clicks: 11", "state rehydrated and the queued click delivered exactly once");
    assert.strictEqual(await page.evaluate(() => AzuSpark.queued), 0);
    assert((await log("reconnect")).length >= 4 && (await log("open")).length >= 1);
    console.log(`ok   backoff delays ${delays.join(", ")} ms, rehydrated, queued click delivered once`);

    // 2. A half open connection (traffic vanishes, nothing closes) is found by the heartbeat.
    proxy.blackhole = true;
    await page.waitForSelector("html:not([data-spark-status=connected])", { timeout: 10000 });
    proxy.blackhole = false;
    proxy.sever();
    await connected();
    await page.click("#inc");
    await page.waitForFunction(() => document.querySelector("#count").textContent === "Clicks: 12");
    console.log("ok   heartbeat detects a half open connection, state kept");

    // 3. The server goes away (close 1012): the client reconnects.
    const closes = (await log("close")).length;
    proxy.goAway(1012);
    await page.waitForFunction((n) => window.__log.filter((e) => e.name === "close").length > n, closes);
    const closed = await log("close");
    assert.strictEqual(closed[closed.length - 1].code, 1012, JSON.stringify(closed));
    await connected();
    await page.click("#inc");
    await page.waitForFunction(() => document.querySelector("#count").textContent === "Clicks: 13");
    console.log("ok   reconnects after the server goes away (1012)");

    // 4. The browser goes offline: no reconnect attempts until it is back online.
    proxy.attempts.length = 0;
    await page.context().setOffline(true);
    await page.waitForSelector("html:not([data-spark-status=connected])", { timeout: 10000 });
    await sleep(2500);
    await page.context().setOffline(false);
    await connected();
    await page.click("#inc");
    await page.waitForFunction(() => document.querySelector("#count").textContent === "Clicks: 14");
    console.log("ok   waits for the browser to come back online");

    await scriptedSocket(browser);
    console.log("ok   queue keeps one event per control and waits for the rejoin after a refused snapshot");

    await visibilityProbe(browser);
    console.log("ok   a tab that becomes visible probes the connection and drops it when unanswered");
  } finally {
    if (browser) await browser.close();
    proxy.server.close();
    proxy.sever();
    try { process.kill(-app.pid, "SIGKILL"); } catch (e) { /* gone */ }
  }
}

main().then(() => process.exit(0), (error) => { console.error("FAIL", error); process.exit(1); });

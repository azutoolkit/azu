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

const APP_PORT = Number(process.env.BROWSER_TEST_PORT || 3917);
const PROXY_PORT = APP_PORT + 1;
const URL_ = `http://127.0.0.1:${PROXY_PORT}/`;
const REQUIRED = process.env.SPARK_BROWSER_REQUIRED === "1";

function skip(reason) {
  console.log(`SKIP spark browser test: ${reason}`);
  process.exit(REQUIRED ? 1 : 0);
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

// ---- scenarios ------------------------------------------------------------------------

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const { chromium } = loadPlaywright();
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
    await page.goto(URL_);
    const connected = () => page.waitForSelector("html[data-spark-status=connected]", { timeout: 20000 });
    const count = () => page.textContent("#count");
    await page.evaluate(() => {
      window.__log = [];
      for (const name of ["open", "close", "reconnect", "error"]) AzuSpark.on(name, (detail) => window.__log.push({ name, ...detail }));
    });
    await connected();
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
    await sleep(9000);
    const gaps = proxy.attempts.slice(1).map((at, i) => at - proxy.attempts[i]);
    assert(proxy.attempts.length >= 4, `expected several reconnect attempts, got ${proxy.attempts.length}`);
    gaps.forEach((gap, i) => { if (i > 0) assert(gap >= gaps[i - 1] - 150, `backoff must not shrink: ${gaps}`); });
    assert(gaps[gaps.length - 1] >= gaps[0] * 1.5, `backoff must grow: ${gaps}`);
    proxy.refusing = false;
    await connected();
    await page.waitForFunction(() => document.querySelector("#count").textContent === "Clicks: 11", null, { timeout: 20000 });
    await sleep(1500);
    assert.strictEqual(await count(), "Clicks: 11", "state rehydrated and the queued click delivered exactly once");
    assert.strictEqual(await page.evaluate(() => AzuSpark.queued), 0);
    assert((await log("reconnect")).length >= 4 && (await log("open")).length >= 1);
    console.log(`ok   backoff gaps ${gaps.join(", ")} ms, rehydrated, queued click delivered once`);

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
  } finally {
    if (browser) await browser.close();
    proxy.server.close();
    proxy.sever();
    try { process.kill(-app.pid, "SIGKILL"); } catch (e) { /* gone */ }
  }
}

main().then(() => process.exit(0), (error) => { console.error("FAIL", error); process.exit(1); });

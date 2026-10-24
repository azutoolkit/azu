// Browser test of event delivery: fast typing coalesces, and an event in flight when the connection
// is cut takes effect exactly once after the reconnect.
//
//   spec/browser/run.sh          # see there for the requirements
//
// Drives playground/spark_demo/app.cr (its Echo field and its slow counter button) through a TCP
// proxy that can cut every connection. Missing playwright or chromium means SKIP (exit 0), unless
// SPARK_BROWSER_REQUIRED=1.
const net = require("net");
const http = require("http");
const assert = require("assert");
const { spawn } = require("child_process");

let APP_PORT;
let PROXY_PORT;
let URL_;
const REQUIRED = process.env.SPARK_BROWSER_REQUIRED === "1";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function skip(reason) {
  console.log(`SKIP spark delivery browser test: ${reason}`);
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

// A TCP proxy between the browser and the app that can cut every connection.
class Proxy {
  constructor() {
    this.sockets = new Set();
    this.server = net.createServer((client) => {
      const upstream = net.connect(APP_PORT, "127.0.0.1");
      this.sockets.add(client).add(upstream);
      client.pipe(upstream);
      upstream.pipe(client);
      const end = () => { client.destroy(); upstream.destroy(); this.sockets.delete(client); this.sockets.delete(upstream); };
      client.on("error", end).on("close", end);
      upstream.on("error", end).on("close", end);
    });
  }

  listen() { return new Promise((resolve) => this.server.listen(PROXY_PORT, "127.0.0.1", resolve)); }
  sever() { this.sockets.forEach((socket) => socket.destroy()); this.sockets.clear(); }
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
      http.get(`http://127.0.0.1:${APP_PORT}/`, (res) => { res.resume(); resolve(); })
        .on("error", () => (Date.now() > deadline ? reject(new Error("app did not start")) : setTimeout(attempt, 500)));
    };
    attempt();
  });
}

// The page records every event frame it sends, with the number of the socket that carried it.
async function open(browser) {
  const page = await (await browser.newContext()).newPage();
  page.on("pageerror", (error) => { throw error; });
  await page.addInitScript(() => {
    window.__events = [];
    window.__sockets = 0;
    const Native = window.WebSocket;
    window.WebSocket = class extends Native {
      constructor(...args) {
        super(...args);
        const index = ++window.__sockets;
        const send = this.send.bind(this);
        this.send = (data) => {
          const frame = JSON.parse(data);
          if (frame.type === "event") window.__events.push({ socket: index, ...frame });
          return send(data);
        };
      }
    };
  });
  await page.goto(URL_);
  await page.waitForSelector("html[data-spark-status=connected]", { timeout: 20000 });
  return page;
}

async function fastTypingCoalesces(browser) {
  const page = await open(browser);
  const text = "hello coalescing world";
  await page.click("#echo");
  await page.keyboard.type(text, { delay: 0 });
  await page.waitForFunction((expected) => document.querySelector("#echoed").textContent === `Echo: ${expected}`, text, { timeout: 15000 });
  await sleep(600); // nothing late may follow
  const edits = Number((await page.textContent("#edits")).replace("Edits: ", ""));
  const sent = await page.evaluate(() => window.__events.filter((e) => e.event === "edit").length);
  assert(edits < text.length, `the server applied ${edits} edits for ${text.length} keystrokes: nothing coalesced`);
  assert.strictEqual(edits, sent, "every event that was sent was applied once");
  assert.strictEqual(await page.inputValue("#echo"), text, "the field kept what was typed while patches arrived");
  assert.strictEqual(await page.evaluate(() => AzuSpark.queued + AzuSpark.unacked), 0);
  const eids = await page.evaluate(() => window.__events.map((e) => e.eid));
  assert(eids.every((eid, i) => i === 0 || eid > eids[i - 1]), `event numbers increase: ${eids}`);
  console.log(`ok   ${text.length} keystrokes became ${edits} events, the last value won`);
  await page.close();
}

async function exactlyOnceAfterCut(browser, proxy) {
  const page = await open(browser);
  const count = async () => Number((await page.textContent("#count")).replace("Clicks: ", ""));
  const before = await count();
  await page.click("#slow"); // the app takes 400 ms
  await page.waitForFunction(() => window.__events.some((e) => e.event === "slow_increment"));
  await sleep(100);
  proxy.sever(); // mid-event: the reply and the diff never arrive
  await page.waitForFunction(() => window.__sockets >= 2 && document.documentElement.dataset.sparkStatus === "connected", null, { timeout: 20000 });
  await page.waitForFunction((n) => document.querySelector("#count").textContent === `Clicks: ${n + 1}`, before, { timeout: 20000 });
  await sleep(1500); // a second application would show up now
  assert.strictEqual(await count(), before + 1, "the event took effect exactly once");
  const sent = await page.evaluate(() => window.__events.filter((e) => e.event === "slow_increment"));
  assert.strictEqual(sent.length, 2, "it was sent, and resent after the reconnect");
  assert.strictEqual(sent[0].eid, sent[1].eid, "with the same number");
  assert.notStrictEqual(sent[0].socket, sent[1].socket, "on another connection");
  assert.strictEqual(await page.evaluate(() => AzuSpark.unacked + AzuSpark.queued), 0);
  console.log("ok   an event cut off in flight was resent with its number and took effect once");
  await page.close();
}

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
    await fastTypingCoalesces(browser);
    await exactlyOnceAfterCut(browser, proxy);
  } finally {
    if (browser) await browser.close();
    proxy.server.close();
    proxy.sever();
    try { process.kill(-app.pid, "SIGKILL"); } catch (e) { /* gone */ }
  }
}

main().then(() => process.exit(0), (error) => { console.error("FAIL", error); process.exit(1); });

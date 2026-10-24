// Browser test of compressed Spark frames, on playground/spark_demo/app.cr (its Ledger component
// patches about 18 KB of markup per "Next page").
//
//   spec/browser/run.sh          # see there for the requirements
//
// Two tabs do the same clicks: one as a modern browser (announces gzip, receives binary frames), one
// whose DecompressionStream was removed before the script ran (announces nothing, receives text, as
// every client did before). Both must end with the same DOM; the frames are read from the DevTools
// protocol (opcode 1 text, 2 binary) to count the bytes on the wire. Then a gzip bomb is delivered to
// the compressing tab: it must refuse it, report patch_failed, rejoin without announcing gzip, and
// keep working. Missing playwright or chromium means SKIP (exit 0), unless SPARK_BROWSER_REQUIRED=1.
const net = require("net");
const http = require("http");
const assert = require("assert");
const { spawn } = require("child_process");

let APP_PORT;
let URL_;
const REQUIRED = process.env.SPARK_BROWSER_REQUIRED === "1";

function skip(reason) {
  console.log(`SKIP spark compress browser test: ${reason}`);
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

// Opens the demo page; *modern* false removes DecompressionStream first. Every WebSocket frame is
// recorded: {dir, kind: "text" | "binary", bytes, json?}; the page's socket is kept in window.__ws.
async function open(browser, modern) {
  const page = await (await browser.newContext()).newPage();
  const frames = [];
  page.on("pageerror", (error) => { throw error; });
  await page.addInitScript((keep) => {
    if (!keep) delete window.DecompressionStream;
    const Plain = WebSocket;
    window.WebSocket = class extends Plain { constructor(...args) { super(...args); window.__ws = this; } };
    window.__errors = [];
    document.addEventListener("spark:error", (event) => window.__errors.push(event.detail.code));
  }, modern);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Network.enable");
  const record = (dir) => ({ response }) => {
    const binary = response.opcode === 2;
    const bytes = binary ? Buffer.from(response.payloadData, "base64").length : Buffer.byteLength(response.payloadData);
    const frame = { dir, kind: binary ? "binary" : "text", bytes };
    if (!binary) { try { frame.json = JSON.parse(response.payloadData); } catch (e) { /* not JSON */ } }
    frames.push(frame);
  };
  cdp.on("Network.webSocketFrameReceived", record("in"));
  cdp.on("Network.webSocketFrameSent", record("out"));
  await page.goto(URL_);
  await page.waitForSelector("html[data-spark-status=connected]", { timeout: 20000 });
  return { page, frames };
}

const ledger = (page) => page.evaluate(() => ({ title: document.querySelector("#ledger-page").textContent, rows: document.querySelector("#ledger-rows").innerHTML }));

async function turn(page, times) {
  for (let i = 0; i < times; i++) await page.click("#ledger-turn");
}

async function settled(page, title) {
  await page.waitForFunction((t) => document.querySelector("#ledger-page").textContent === t, title, { timeout: 10000 });
}

const diffBytes = (frames) => frames.filter((f) => f.dir === "in" && f.kind === "binary").reduce((n, f) => n + f.bytes, 0);

async function compare(browser) {
  const modern = await open(browser, true);
  const old = await open(browser, false);

  // The join of each: the modern tab announces gzip, the old one sends exactly what protocol v1 had.
  const joins = (tab) => tab.frames.filter((f) => f.dir === "out" && f.json && f.json.type === "join");
  assert(joins(modern).every((j) => JSON.stringify(j.json.enc) === '["gzip"]'), "the modern tab announces gzip");
  assert(joins(old).every((j) => !("enc" in j.json)), "the old tab announces nothing");
  console.log("ok   the join announces gzip only where DecompressionStream exists");

  // Same clicks, quickly (replies and binary diffs interleave), then the same final DOM.
  await turn(modern.page, 6);
  await turn(old.page, 6);
  await settled(modern.page, "Ledger page 7");
  await settled(old.page, "Ledger page 7");
  assert.deepStrictEqual(await ledger(modern.page), await ledger(old.page), "both tabs show the same page");
  assert.strictEqual((await ledger(modern.page)).rows.includes("INV-"), true);
  console.log("ok   a large patch arrives compressed and applies exactly as the text one");

  assert(modern.frames.some((f) => f.dir === "in" && f.kind === "binary"), "the modern tab received binary frames");
  assert(!old.frames.some((f) => f.kind === "binary"), "the old tab received only text frames");
  const kinds = modern.frames.filter((f) => f.dir === "in" && (f.kind === "binary" || (f.json && f.json.type === "reply"))).map((f) => f.kind);
  assert(kinds.join(",").includes("binary,text,binary,text"), `binary diffs and text replies interleave (${kinds.join(",")})`);
  const replies = modern.frames.filter((f) => f.dir === "in" && f.json && f.json.type === "reply").length;
  assert(replies >= 7, `every event was answered (${replies} replies)`);
  console.log("ok   binary and text frames interleave and the page ends on the last click");

  // Wire bytes for the six turns: the diff frames only (replies and heartbeats are the same in both).
  const wire = (tab, binary) => tab.frames.filter((f) => f.dir === "in" && (binary ? f.kind === "binary" : f.json && f.json.type === "diff")).reduce((n, f) => n + f.bytes, 0);
  const packed = wire(modern, true);
  const plain = wire(old, false);
  console.log(`bytes on the wire for the join and 6 page turns: ${plain} as text, ${packed} compressed (${(plain / packed).toFixed(1)}x smaller, ${(100 - (100 * packed / plain)).toFixed(0)}% saved)`);
  const turnFrames = modern.frames.filter((f) => f.dir === "in" && f.kind === "binary").slice(-6).map((f) => f.bytes);
  const oldTurns = old.frames.filter((f) => f.dir === "in" && f.json && f.json.type === "diff").slice(-6).map((f) => f.bytes);
  console.log(`last six diffs: text ${oldTurns.join(", ")} B, gzip ${turnFrames.join(", ")} B`);
  assert(packed * 3 < plain, "compression saves at least two thirds");

  // A gzip bomb arrives (as if a server or a proxy misbehaved): refused while it inflates.
  const before = joins(modern).length;
  await modern.page.evaluate(async () => {
    const stream = new Blob([new Uint8Array(4 * 1024 * 1024).fill(32)]).stream().pipeThrough(new CompressionStream("gzip"));
    const bomb = await new Response(stream).arrayBuffer();
    window.__bomb = bomb.byteLength;
    window.__ws.onmessage({ data: bomb });
  });
  assert((await modern.page.evaluate(() => window.__bomb)) < 20000, "the bomb is small on the wire");
  await modern.page.waitForFunction(() => window.__errors.includes("patch_failed"), null, { timeout: 10000 });
  await modern.page.waitForFunction((n) => document.documentElement.getAttribute("data-spark-status") === "connected" && window.__ws.readyState === 1, before, { timeout: 20000 });
  await modern.page.waitForFunction(() => document.querySelector("#ledger-page"), null, { timeout: 5000 });
  const rejoins = joins(modern).slice(before);
  assert(rejoins.length > 0 && rejoins.every((j) => !("enc" in j.json)), "after an unreadable frame the tab rejoins asking for plain frames");
  console.log("ok   a gzip bomb is refused (patch_failed), the tab rejoins and asks for plain frames");

  // The rejoined tab (restored from its snapshot) keeps working with text frames only.
  await turn(modern.page, 1);
  await settled(modern.page, "Ledger page 8");
  assert(modern.frames.slice(-3).every((f) => f.kind !== "binary" || f.dir !== "in"), "no binary frame after the rejoin");
  console.log("ok   the page keeps working on text frames after the failure");
  await modern.page.context().close();
  await old.page.context().close();
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
    await compare(browser);
    console.log("spark compress browser test passed");
  } finally {
    if (browser) await browser.close().catch(() => {});
    try { process.kill(-app.pid, "SIGTERM"); } catch (e) { /* already gone */ }
  }
}

main().then(() => process.exit(0), (error) => { console.error(error); process.exit(1); });

#!/usr/bin/env node
// Client benchmarks of the Spark patch engine, event pipeline, frame handling and memory, in Chromium.
//
//   node benchmark/spark/client.mjs [--mode short|full] [--only patch,keystrokes,frame,memory] [--out FILE.json]
//
// Every number is a same-session comparison between arms measured interleaved on one box:
//   naive    a page with no Spark client that replaces the component with innerHTML (and, for events,
//            sends one frame per input event): what you get without a patch engine
//   prev     the client at the commit before slice 3 (BENCH_PREV_COMMIT, default 2c373cd), taken from git
//   current  the client in this checkout (src/azu/spark/client/azu_spark.js, the shipped script)
// The page is served from memory (no network, no server), the WebSocket is a fake the harness drives and
// requestAnimationFrame is replaced by a queue the harness pumps, so a patch is timed from "the frame
// arrived" to "the new layout is computed", without waiting for the display. Painting and rasterising
// are not measured. Needs playwright (PLAYWRIGHT_MODULE) and chromium (CHROMIUM_PATH).
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { captureEnv, metric, settings, writeResult } from "./lib.mjs";

const root = fileURLToPath(new URL("../..", import.meta.url));
const require = createRequire(import.meta.url);
const args = process.argv.slice(2);
const option = (name, fallback = null) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);
const mode = option("--mode", "short");
const knobs = settings(mode);
const only = (option("--only") || "patch,keystrokes,frame,memory").split(",");
const PREV_COMMIT = process.env.BENCH_PREV_COMMIT || "2c373cd";

function loadPlaywright() {
  for (const name of [process.env.PLAYWRIGHT_MODULE, "playwright", "playwright-core"].filter(Boolean)) {
    try { return require(name); } catch { /* try the next */ }
  }
  console.error("playwright is not installed (npm i playwright, or set PLAYWRIGHT_MODULE)");
  process.exit(3);
}

function artifacts() {
  const current = readFileSync(`${root}/src/azu/spark/client/azu_spark.js`, "utf8");
  const found = { current };
  try {
    found.prev = execFileSync("git", ["-C", root, "show", `${PREV_COMMIT}:src/azu/spark/client/azu_spark.js`], { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  } catch {
    console.error(`WARNING: commit ${PREV_COMMIT} is not in this clone (shallow?): the prev arm is skipped`);
  }
  return found;
}

// ---- the page --------------------------------------------------------------------------------

const PAGE = (withClient, inner = "") => `<!doctype html><html><head><meta charset="utf-8"><style>
body{font:14px sans-serif;margin:0} li{list-style:none;padding:2px 6px;border-bottom:1px solid #ddd} input{display:block}
</style></head><body><div data-spark-root data-spark-id="r" data-spark-token="t"><div data-spark-id="r~c" id="host">${inner}</div></div>${withClient ? '<script src="/azu_spark.js"></script>' : ""}</body></html>`;

// Runs before the page: a fake socket, a manual animation-frame queue, and the case builders.
const INIT = () => {
  const queue = [];
  window.requestAnimationFrame = (callback) => { queue.push(callback); return queue.length; };
  window.cancelAnimationFrame = () => {};
  window.__pump = () => { while (queue.length) for (const callback of queue.splice(0)) callback(performance.now()); };
  window.__sent = [];
  window.FakeWS = class {
    constructor() { this.readyState = 1; window.__ws = this; }
    send(text) { const message = JSON.parse(text); window.__sent.push(message); window.__last = message; }
    close() {}
  };
  Object.assign(window.FakeWS, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
  window.WebSocket = window.FakeWS;
  window.__frame = (frame) => window.__ws.onmessage({ data: JSON.stringify({ v: 1, ...frame }) });
};

// Installed once per page, after the client is up. `arm` is naive, prev or current.
const BENCH = (arm) => {
  const host = document.getElementById("host");
  const mulberry = (seed) => () => { seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const permutation = (n, seed) => { const a = Array.from({ length: n }, (_, i) => i); const r = mulberry(seed); for (let i = n - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };
  const row = (k, label) => `<li id="row-${k}"><span class="n">${k}</span> <span class="label">${label ?? `Row ${k}`}</span> <button spark-click="pick" spark-value-id="${k}">pick</button></li>`;
  const list = (order, label) => `<ul id="list">${order.map((k) => row(k, label && label(k))).join("")}</ul>`;
  const cases = {
    reorder: (n) => ({ states: [list(permutation(n, 0).sort((a, b) => a - b)), list(permutation(n, 7))], expect: (i) => n }),
    swap: (n) => { const a = Array.from({ length: n }, (_, i) => i); const b = a.slice(); [b[1], b[n - 2]] = [b[n - 2], b[1]]; return { states: [list(a), list(b)], expect: () => n }; },
    update: (n) => { const a = Array.from({ length: n }, (_, i) => i); return { states: [list(a), list(a, (k) => (k === Math.floor(n / 2) ? "Row changed" : null))], expect: () => n }; },
    plain: (n) => { const rows = (label) => `<ul>${Array.from({ length: n }, (_, k) => `<li><span>${k === Math.floor(n / 2) ? label : "Row " + k}</span> <button spark-click="pick">pick</button></li>`).join("")}</ul>`; return { states: [rows("a"), rows("b")], expect: () => n }; },
    bigtext: (bytes) => { const words = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor".split(" "); const r = mulberry(3); let text = ""; while (text.length < bytes) text += words[Math.floor(r() * words.length)] + " "; const half = Math.floor(text.length / 2); const b = text.slice(0, half) + "EDITED " + text.slice(half + 7); return { states: [`<p id="big">${text}</p>`, `<p id="big">${b}</p>`], texts: [text, b], expect: () => 1 }; },
    form: (n) => { const inputs = (status) => `<form id="f"><p id="status">${status}</p>${Array.from({ length: n }, (_, i) => `<label>Field ${i} <input id="f${i}" name="f${i}" type="text" value=""></label>`).join("")}</form>`; return { states: [inputs("idle"), inputs("saving")], expect: () => n }; },
  };
  const bench = {
    arm,
    current: null,
    i: 0,
    deliver(html) {
      const text = JSON.stringify({ v: 1, type: "diff", seq: ++bench.seq, patches: [{ id: "r~c", html }], events: [], snapshots: {} });
      return text;
    },
    seq: 0,
    prepare(kind, size) {
      const c = cases[kind](size);
      bench.current = { ...c, kind, size, frames: c.states.map((html) => bench.deliver(html)), htmls: c.states };
      bench.i = 0;
      bench.apply(0);
      bench.apply(1); // a real toggle pair 0 -> 1 -> 0 before anything is measured
      bench.apply(0);
    },
    apply(index) {
      const { frames, htmls } = bench.current;
      const t0 = performance.now();
      if (arm === "naive") host.innerHTML = JSON.parse(frames[index]).patches[0].html;
      else { window.__ws.onmessage({ data: frames[index] }); window.__pump(); }
      host.getBoundingClientRect();
      if (host.lastElementChild) host.lastElementChild.getBoundingClientRect();
      return performance.now() - t0;
    },
    /** Applies the other state *batch* times; returns the mean ms per patch. */
    step(batch) {
      let total = 0;
      for (let b = 0; b < batch; b++) { bench.i ^= 1; total += bench.apply(bench.i); }
      return total / batch;
    },
    /** The page shows the state the last patch carried: row count and order, or the text. */
    verify() {
      const { kind, size, htmls, texts } = bench.current;
      if (kind === "bigtext") return host.querySelector("#big").textContent === texts[bench.i];
      if (kind === "plain") return host.querySelectorAll("li").length === size && host.querySelectorAll("li span")[Math.floor(size / 2)].textContent === (bench.i ? "b" : "a");
      if (kind === "form") return host.querySelectorAll("input").length === size && host.querySelector("#status").textContent === (bench.i ? "saving" : "idle");
      const want = [...htmls[bench.i].matchAll(/id="row-(\d+)"/g)].map((m) => m[1]);
      const have = [...host.querySelectorAll("li")].map((li) => li.id.slice(4));
      return want.length === have.length && want.every((id, k) => id === have[k]) && (kind !== "update" || host.querySelector(`#row-${Math.floor(size / 2)} .label`).textContent === (bench.i ? "Row changed" : `Row ${Math.floor(size / 2)}`));
    },
    focusPrepare() {
      const input = document.getElementById("f250");
      input.value = "typed"; input.focus(); input.setSelectionRange(3, 3);
    },
    focusKept() {
      const input = document.getElementById("f250");
      return document.activeElement === input && input.value === "typed" && input.selectionStart === 3;
    },
  };
  window.__bench = bench;
};

async function openArm(browser, arm, script, body) {
  const context = await browser.newContext({ viewport: { width: 900, height: 700 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.route("http://bench.local/", (route) => route.fulfill({ contentType: "text/html", body: PAGE(arm !== "naive", body) }));
  if (script) await page.route("http://bench.local/azu_spark.js", (route) => route.fulfill({ contentType: "text/javascript", body: script }));
  await page.addInitScript(INIT);
  await page.goto("http://bench.local/");
  if (arm !== "naive") {
    await page.waitForFunction(() => window.__ws);
    await page.evaluate(() => window.__frame({ type: "hello", heartbeat: 20000, max_size: 65536 }));
    await page.evaluate(() => window.__frame({ type: "reply", id: window.__last.id }));
  }
  await page.evaluate(BENCH, arm);
  return { page, context, errors, arm };
}

/** Closes an arm's context, failing the run when its page raised an error. */
async function closeArm(arm) {
  const errors = arm.errors;
  await arm.context.close();
  if (errors.length) throw new Error(`${arm.arm} raised page errors: ${errors[0]}`);
}

const rotate = (list, by) => list.map((_, i) => list[(i + by) % list.length]);

/** Runs *reps* measured repetitions after one more whose results are dropped (JIT, caches, first layout). */
async function interleaved(arms, reps, work) {
  const results = Object.fromEntries(arms.map((a) => [a.arm, []]));
  for (let rep = 0; rep <= reps; rep++) {
    for (const arm of rotate(arms, rep)) {
      const result = await work(arm, rep);
      if (rep > 0) results[arm.arm].push(result);
    }
  }
  return results;
}

// ---- suites ----------------------------------------------------------------------------------

const PATCH_CASES = [
  { id: "reorder100", kind: "reorder", size: 100, batch: 4 },
  { id: "reorder1000", kind: "reorder", size: 1000, batch: 2 },
  { id: "reorder5000", kind: "reorder", size: 5000, batch: 1 },
  { id: "swap2of1000", kind: "swap", size: 1000, batch: 4 },
  { id: "update1of1000", kind: "update", size: 1000, batch: 8 },
  { id: "unkeyed500", kind: "plain", size: 500, batch: 4 },
  { id: "unkeyed2000", kind: "plain", size: 2000, batch: 1 },
  { id: "bigtext256k", kind: "bigtext", size: 262144, batch: 2 },
  { id: "form500focus", kind: "form", size: 500, batch: 4 },
];

async function patchSuite(arms) {
  const metrics = [];
  for (const spec of PATCH_CASES) {
    for (const arm of arms) await arm.page.evaluate(([k, s]) => window.__bench.prepare(k, s), [spec.kind, spec.size]);
    const kept = Object.fromEntries(arms.map((a) => [a.arm, []]));
    const bad = new Set();
    const samples = await interleaved(arms, knobs.reps, async (arm) => {
      const out = [];
      for (let s = 0; s < knobs.perRep; s++) {
        if (spec.kind === "form") await arm.page.evaluate(() => window.__bench.focusPrepare());
        out.push(await arm.page.evaluate((b) => window.__bench.step(b), spec.batch));
        if (spec.kind === "form") kept[arm.arm].push(await arm.page.evaluate(() => window.__bench.focusKept()));
      }
      if (!(await arm.page.evaluate(() => window.__bench.verify()))) bad.add(arm.arm);
      return out;
    });
    for (const arm of arms) {
      const extra = spec.kind === "form" ? { focus_kept: kept[arm.arm].filter(Boolean).length / kept[arm.arm].length } : undefined;
      if (bad.has(arm.arm)) throw new Error(`${arm.arm} did not produce the expected page in case ${spec.id}`);
      // The naive arm is the baseline that loses focus; every Spark engine claims to keep it, so losing it fails the run.
      if (spec.kind === "form" && arm.arm !== "naive" && extra.focus_kept !== 1) throw new Error(`${arm.arm} lost focus, value or caret in ${spec.id} (kept ${extra.focus_kept})`);
      metrics.push(metric(`client.patch.${spec.id}.${arm.arm}`, "ms", samples[arm.arm], { extra, floor: 0.05 }));
    }
    console.error(`  patch ${spec.id}: ${arms.map((a) => `${a.arm} ${metrics.at(-arms.length + arms.indexOf(a)).median} ms`).join(", ")}`);
  }
  return metrics;
}

async function pipelineSuite(browser, scripts) {
  const metrics = [];
  const arms = [];
  const field = '<input id="in" name="echo" type="text" spark-change="edit">';
  for (const arm of ["naive", "prev", "current"].filter((a) => a === "naive" || scripts[a])) {
    const opened = await openArm(browser, arm, scripts[arm], field);
    if (arm === "naive") {
      await opened.page.evaluate(() => {
        window.__naiveSeq = 0;
        document.getElementById("in").addEventListener("input", (e) => window.__ws.send(JSON.stringify({ v: 1, type: "event", id: ++window.__naiveSeq, target: "r~c", event: "edit", payload: { value: e.target.value } })));
        window.__ws = new window.FakeWS();
      });
    }
    arms.push(opened);
  }
  for (const [name, ackEvery] of [["burst", 0], ["acked10", 10]]) {
    const samples = await interleaved(arms, knobs.reps, async (arm) => arm.page.evaluate(([n, every]) => {
      const input = document.getElementById("in");
      const naive = window.__bench.arm === "naive";
      const acknowledge = () => { for (const m of window.__sent) if (m.type === "event" && !m.__acked) { m.__acked = true; window.__frame({ type: "reply", id: m.id, ack: m.eid }); } };
      // Whatever the previous run left in flight is answered first, so every run starts from an idle pipeline.
      const settle = () => { if (naive) return; for (let i = 0; i < 20; i++) { acknowledge(); window.__pump(); } };
      settle();
      window.__sent.length = 0;
      const t0 = performance.now();
      for (let i = 0; i < n; i++) {
        input.value = `key${i}`;
        input.dispatchEvent(new Event("input", { bubbles: true }));
        if (every && i % every === every - 1 && !naive) { acknowledge(); window.__pump(); }
      }
      window.__pump();
      const ms = performance.now() - t0;
      const frames = window.__sent.filter((m) => m.type === "event").length;
      settle();
      // The server must end up with the text the user ended with: the last frame carries the final value.
      const events = window.__sent.filter((m) => m.type === "event");
      const last = events[events.length - 1];
      const finalOk = Boolean(last) && JSON.stringify(last.payload).includes(`key${n - 1}"`) && input.value === `key${n - 1}`;
      return { ms, frames, finalOk };
    }, [knobs.keystrokes, ackEvery]));
    for (const arm of arms) {
      const runs = samples[arm.arm];
      if (runs.some((r) => !r.finalOk)) throw new Error(`${arm.arm} ${name}: the last event frame did not carry the final input value`);
      if (runs.every((r) => r.frames === 0)) throw new Error(`${arm.arm} sent no event frames: the harness does not drive it`);
      metrics.push(metric(`client.keystrokes.${name}.${arm.arm}.ms`, "ms", runs.map((r) => [r.ms]), { floor: 0.2 }));
      metrics.push(metric(`client.keystrokes.${name}.${arm.arm}.frames`, "frames", runs.map((r) => [r.frames]), { floor: 1 }));
    }
    console.error(`  keystrokes ${name}: ${arms.map((a) => { const r = samples[a.arm]; return `${a.arm} ${(r.map((x) => x.ms).sort((x, y) => x - y)[Math.floor(r.length / 2)]).toFixed(2)} ms/${r[0].frames} frames`; }).join(", ")}`);
  }
  for (const arm of arms) await closeArm(arm);
  return metrics;
}

async function frameSuite(browser, scripts, moduleSource) {
  const metrics = [];
  const arms = [];
  for (const arm of ["current", "prev"].filter((a) => scripts[a])) arms.push(await openArm(browser, arm, scripts[arm], ""));
  const baseline = await openArm(browser, "naive", null, "");
  const text = JSON.stringify({ v: 1, type: "heartbeat", id: 424242 });
  const samples = await interleaved([...arms, baseline], knobs.reps, (arm) => arm.page.evaluate(([payload, n, parseOnly]) => {
    const t0 = performance.now();
    if (parseOnly) { let sink = 0; for (let i = 0; i < n; i++) sink += JSON.parse(payload).id; window.__sink = sink; }
    else for (let i = 0; i < n; i++) window.__ws.onmessage({ data: payload });
    return [((performance.now() - t0) * 1e6) / n];
  }, [text, knobs.frames, arm.arm === "naive"]));
  for (const arm of [...arms, baseline]) metrics.push(metric(`client.frame.heartbeat.${arm.arm === "naive" ? "json_parse_only" : arm.arm}`, "ns/frame", samples[arm.arm], { floor: 50 }));
  console.error(`  frame: ${[...arms, baseline].map((a) => `${a.arm} ${metrics[metrics.length - 1 - ([...arms, baseline].length - 1 - [...arms, baseline].indexOf(a))].median} ns`).join(", ")}`);
  for (const arm of [...arms, baseline]) await closeArm(arm);

  // The pure transition function of the state machine, from the module source.
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.route("http://bench.local/", (route) => route.fulfill({ contentType: "text/html", body: "<!doctype html><body></body>" }));
  await page.route("http://bench.local/azu-spark.js", (route) => route.fulfill({ contentType: "text/javascript", body: moduleSource }));
  await page.goto("http://bench.local/");
  const transitions = [];
  for (let rep = 0; rep < knobs.reps; rep++) {
    transitions.push([await page.evaluate(async (passes) => {
      const { next, STATES, EVENTS } = await import("http://bench.local/azu-spark.js");
      const states = STATES.map((name) => ({ name, attempts: 2 }));
      const events = EVENTS.map((type) => ({ type, online: true, code: 1006 }));
      let sink = 0;
      const t0 = performance.now();
      for (let p = 0; p < passes; p++) for (const s of states) for (const e of events) sink += next(s, e).effects.length;
      window.__sink = sink;
      return ((performance.now() - t0) * 1e6) / (passes * states.length * events.length);
    }, 300)]);
  }
  metrics.push(metric("client.machine.next", "ns/transition", transitions, { floor: 50 }));
  await context.close();
  return metrics;
}

async function memorySuite(browser, scripts) {
  const metrics = [];
  const names = ["naive", "prev", "current"].filter((a) => a === "naive" || scripts[a]);
  const heap = async (cdp) => {
    for (let i = 0; i < 3; i++) await cdp.send("HeapProfiler.collectGarbage");
    const { usedSize } = await cdp.send("Runtime.getHeapUsage");
    const counters = await cdp.send("Memory.getDOMCounters");
    return { kb: usedSize / 1024, nodes: counters.nodes, listeners: counters.jsEventListeners };
  };
  const retained = Object.fromEntries(names.map((n) => [n, []]));
  const growth = Object.fromEntries(names.map((n) => [n, []]));
  const nodeDelta = Object.fromEntries(names.map((n) => [n, []]));
  for (let rep = 0; rep < knobs.memoryReps; rep++) {
    for (const name of rotate(names, rep)) {
      const arm = await openArm(browser, name, scripts[name], "");
      const cdp = await arm.context.newCDPSession(arm.page);
      await cdp.send("HeapProfiler.enable");
      await arm.page.evaluate(() => window.__bench.prepare("reorder", 150));
      await arm.page.evaluate(() => { for (let i = 0; i < 150; i++) window.__bench.step(1); });
      const check = async () => { if (!(await arm.page.evaluate(() => window.__bench.verify()))) throw new Error(`${name} did not produce the expected page in the memory case`); };
      await check();
      const h0 = await heap(cdp);
      await arm.page.evaluate((n) => window.__bench.step(n), knobs.memoryPatches);
      await check();
      const h1 = await heap(cdp);
      await arm.page.evaluate((n) => window.__bench.step(n), knobs.memoryPatches);
      await check();
      const h2 = await heap(cdp);
      retained[name].push([h1.kb - h0.kb]);
      growth[name].push([((h2.kb - h1.kb) * 1000) / knobs.memoryPatches]);
      nodeDelta[name].push([h2.nodes - h0.nodes + (h2.listeners - h0.listeners)]);
      await closeArm(arm);
    }
  }
  for (const name of names) {
    metrics.push(metric(`client.memory.retained_kb.${name}`, "KB", retained[name], { floor: 256, extra: { patches: knobs.memoryPatches, case: "reorder150" } }));
    metrics.push(metric(`client.memory.growth_kb_per_1000.${name}`, "KB", growth[name], { floor: 256, extra: { case: "reorder150" } }));
    metrics.push(metric(`client.memory.dom_nodes_and_listeners_growth.${name}`, "count", nodeDelta[name], { floor: 50 }));
  }
  console.error(`  memory: ${names.map((n) => `${n} retained ${metrics.find((m) => m.id === `client.memory.retained_kb.${n}`).median} KB, growth ${metrics.find((m) => m.id === `client.memory.growth_kb_per_1000.${n}`).median} KB/1000`).join("; ")}`);
  return metrics;
}

// ---- main ------------------------------------------------------------------------------------

const playwright = loadPlaywright();
const scripts = artifacts();
const moduleSource = readFileSync(`${root}/js/azu-spark.js`, "utf8");
const browser = await playwright.chromium.launch({ args: ["--no-sandbox"], executablePath: process.env.CHROMIUM_PATH || undefined });
const env = captureEnv({ chromium: browser.version() });
const metrics = [];
try {
  console.error(`client benchmarks (${mode}: ${knobs.reps} repetitions, interleaved), prev = ${scripts.prev ? PREV_COMMIT : "missing"}`);
  if (only.includes("patch")) {
    const opened = [];
    for (const arm of ["naive", "prev", "current"]) {
      if (arm !== "naive" && !scripts[arm]) continue;
      opened.push(await openArm(browser, arm, scripts[arm], ""));
    }
    metrics.push(...(await patchSuite(opened)));
    for (const arm of opened) {
      await closeArm(arm);
    }
  }
  if (only.includes("keystrokes")) metrics.push(...(await pipelineSuite(browser, scripts)));
  if (only.includes("frame")) metrics.push(...(await frameSuite(browser, scripts, moduleSource)));
  if (only.includes("memory")) metrics.push(...(await memorySuite(browser, scripts)));
} finally {
  await browser.close();
}
if (option("--out")) writeResult(option("--out"), { suite: "client", mode, env, metrics });
else console.log(JSON.stringify(metrics, null, 2));

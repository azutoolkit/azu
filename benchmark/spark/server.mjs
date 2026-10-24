#!/usr/bin/env node
// Runs the server benchmarks: starts the Crystal bench server, drives it with the Crystal load
// generator (separate processes), and writes the metrics as a result file.
//
//   node benchmark/spark/server.mjs --bin PATH [--mode short|full] [--out FILE.json]
//
// BENCH_EXEC_PREFIX runs the binary through a wrapper (for example a docker command that mounts the
// checkout), BENCH_CRYSTAL_VERSION records the compiler version in the result.
import { spawn, execFileSync, spawnSync } from "node:child_process";
import { captureEnv, metric, writeResult } from "./lib.mjs";

const args = process.argv.slice(2);
const option = (name, fallback = null) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);
const mode = option("--mode", "short");
const bin = option("--bin");
if (!bin) { console.error("usage: server.mjs --bin PATH [--mode short|full] [--out FILE]"); process.exit(2); }
const prefix = (process.env.BENCH_EXEC_PREFIX || "").split(/\s+/).filter(Boolean);
const full = mode === "full";
const reps = full ? 15 : 10;
// A server the runner failed to stop ends itself: long enough for the whole suite of its mode.
const serverTtl = full ? 3600 : 1800;

const exec = (extra) => [...prefix, bin, ...extra];

function startServer(nodelay = true) {
  const [command, ...rest] = exec(["serve", "--ttl", String(serverTtl), ...(nodelay ? ["--nodelay"] : [])]);
  const child = spawn(command, rest, { stdio: ["ignore", "pipe", "inherit"], env: process.env });
  return new Promise((resolve, reject) => {
    let buffer = "";
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      const match = buffer.match(/PORT=(\d+)/);
      if (match) resolve({ child, port: Number(match[1]) });
    });
    child.on("exit", (code) => reject(new Error(`server exited early (${code})`)));
    setTimeout(() => { child.kill("SIGKILL"); reject(new Error("server did not start")); }, 60000).unref();
  });
}

function load(port, kind, flags) {
  const [command, ...rest] = exec(["load", kind, "--port", String(port), ...flags.map(String)]);
  const run = spawnSync(command, rest, { encoding: "utf8", timeout: 120000, env: process.env });
  if (run.status !== 0) throw new Error(`load ${kind} ${flags.join(" ")} failed: ${run.stderr || run.stdout}`);
  return JSON.parse(run.stdout.trim().split("\n").at(-1));
}

/** Asks the server to exit (the only way through a docker wrapper), then kills the wrapper process itself. */
async function stop(child, port) {
  try { await fetch(`http://127.0.0.1:${port}/stop`, { signal: AbortSignal.timeout(5000) }); } catch { /* already gone */ }
  child.kill("SIGTERM");
}

const rotate = (list, by) => list.map((_, i) => list[(i + by) % list.length]);

async function eventsSuite(port) {
  const metrics = [];
  const configs = [
    { id: "c1n1", conns: 1, components: 1 },
    { id: "c10n1", conns: 10, components: 1 },
    { id: "c50n1", conns: 50, components: 1 },
    { id: "c10n20", conns: 10, components: 20 },
  ];
  const total = full ? 20000 : 4000;
  for (const config of configs) {
    const perConn = Math.max(100, Math.floor(total / config.conns));
    const runs = { on: [], off: [] };
    for (let rep = 0; rep < reps; rep++) {
      for (const arm of rotate(["on", "off"], rep)) runs[arm].push(load(port, "events", ["--conns", config.conns, "--components", config.components, "--events", perConn, "--eid", arm]));
    }
    for (const arm of ["on", "off"]) {
      const id = `server.events.${config.id}.eid_${arm}`;
      metrics.push(metric(`${id}.events_per_s`, "events/s", runs[arm].map((r) => [r.events_per_s]), { better: "higher" }));
      metrics.push(metric(`${id}.closed_loop_p50_ms`, "ms", runs[arm].map((r) => [r.p50_ms]), { floor: 0.05, extra: { closedLoop: true } }));
      metrics.push(metric(`${id}.closed_loop_p99_ms`, "ms", runs[arm].map((r) => [r.p99_ms]), { floor: 0.1, extra: { closedLoop: true, note: "lower bound of the open-loop tail" } }));
    }
    const pick = (arm) => metrics.find((m) => m.id === `server.events.${config.id}.eid_${arm}.events_per_s`).median;
    console.error(`  events ${config.id}: eid on ${Math.round(pick("on"))} /s, off ${Math.round(pick("off"))} /s`);
  }
  return metrics;
}

// The same event round trip on a server that keeps Nagle's algorithm on (the default of Crystal's HTTP server).
async function nagleSuite() {
  const { child, port } = await startServer(false);
  const runs = [];
  try {
    for (let rep = 0; rep < reps; rep++) runs.push(load(port, "events", ["--conns", 10, "--components", 1, "--events", 100, "--eid", "on"]));
  } finally {
    await stop(child, port);
  }
  const metrics = [
    metric("server.events.c10n1.nagle_on.events_per_s", "events/s", runs.map((r) => [r.events_per_s]), { better: "higher", extra: { note: "default sockets: diff and reply are two writes" } }),
    metric("server.events.c10n1.nagle_on.closed_loop_p50_ms", "ms", runs.map((r) => [r.p50_ms]), { floor: 0.5 }),
  ];
  console.error(`  events with Nagle on (default sockets): ${Math.round(metrics[0].median)} /s, p50 ${metrics[1].median} ms`);
  return metrics;
}

async function fanoutSuite(port) {
  const metrics = [];
  const configs = [
    { id: "m10", conns: 10, messages: 20, interval: 20 },
    { id: "m100", conns: 100, messages: 20, interval: 20 },
    { id: "m500", conns: 500, messages: 10, interval: 40 },
    { id: "m100burst", conns: 100, messages: 20, interval: 0 },
  ];
  for (const config of configs) {
    const runs = [];
    for (let rep = 0; rep < reps; rep++) runs.push(load(port, "fanout", ["--conns", config.conns, "--messages", config.messages, "--interval-ms", config.interval]));
    const lost = runs.reduce((sum, r) => sum + r.lost, 0);
    const id = `server.fanout.${config.id}`;
    metrics.push(metric(`${id}.p50_ms`, "ms", runs.map((r) => [r.p50_ms]), { floor: 0.2, extra: { lost } }));
    metrics.push(metric(`${id}.p99_ms`, "ms", runs.map((r) => [r.p99_ms]), { floor: 0.5, extra: { lost } }));
    // Paced runs deliver at the pace of the publisher, so only the burst reports a rate.
    if (config.interval === 0) metrics.push(metric(`${id}.deliveries_per_s`, "deliveries/s", runs.map((r) => [r.deliveries_per_s]), { better: "higher" }));
    console.error(`  fanout ${config.id}: p50 ${metrics.find((m) => m.id === `${id}.p50_ms`).median} ms, p99 ${metrics.find((m) => m.id === `${id}.p99_ms`).median} ms${config.interval === 0 ? `, ${Math.round(metrics.at(-1).median)} deliveries/s` : ""}, lost ${lost}`);
  }
  return metrics;
}

async function memorySuite(port) {
  const metrics = [];
  for (const config of [{ id: "c100n1", conns: 100, components: 1 }, { id: "c100n10", conns: 100, components: 10 }]) {
    const runs = [];
    for (let rep = 0; rep < 6; rep++) runs.push(load(port, "memory", ["--conns", config.conns, "--components", config.components]));
    const id = `server.memory.${config.id}`;
    metrics.push(metric(`${id}.rss_kb_per_conn`, "KB", runs.map((r) => [r.rss_kb_per_conn]), { floor: 8 }));
    metrics.push(metric(`${id}.used_kb_per_conn`, "KB", runs.map((r) => [r.used_kb_per_conn]), { floor: 8 }));
    metrics.push(metric(`${id}.used_kb_after_close_median`, "KB", runs.map((r) => [r.used_kb_after_close]), { floor: 1024 }));
    // The heap in use with no connection open, after each cycle: the first cycle warms pools up, a leak
    // keeps rising afterwards. The drift is the rise per cycle from the second cycle on.
    const after = runs.map((r) => r.used_kb_after_close);
    const drift = after.length > 2 ? (after.at(-1) - after[1]) / (after.length - 2) : 0;
    metrics.push(metric(`${id}.used_kb_drift_per_cycle`, "KB", [[drift]], { floor: 512, extra: { used_kb_after_each_cycle: after } }));
    console.error(`  memory ${config.id}: rss ${metrics[metrics.length - 4].median} KB/conn, GC-used ${metrics[metrics.length - 3].median} KB/conn, heap in use with no connection per cycle ${after.join(" ")} KB (drift ${Math.round(drift)} KB/cycle)`);
  }
  return metrics;
}

function microSuite() {
  const results = new Map();
  const runs = full ? 5 : 3;
  for (let rep = 0; rep < runs; rep++) {
    const [command, ...rest] = exec(["micro"]);
    const output = execFileSync(command, rest, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], env: process.env, maxBuffer: 16 * 1024 * 1024 });
    const line = output.split("\n").find((candidate) => candidate.startsWith("RESULT "));
    if (!line) throw new Error("the micro benchmark printed no RESULT line");
    for (const item of JSON.parse(line.slice(7))) {
      if (!results.has(item.label)) results.set(item.label, []);
      results.get(item.label).push([item.ns_per_op]);
    }
  }
  const metrics = [...results].map(([label, reps]) => metric(`server.micro.${label.replace(/[^a-z0-9]+/gi, "_").replace(/_$/, "").toLowerCase()}`, "ns/op", reps, { floor: 20 }));
  console.error(`  micro: ${metrics.map((m) => `${m.id.replace("server.micro.", "")} ${Math.round(m.median)} ns`).join(", ")}`);
  return metrics;
}

console.error(`server benchmarks (${mode}); sockets with TCP_NODELAY unless stated`);
const { child, port } = await startServer();
const metrics = [];
try {
  metrics.push(...(await eventsSuite(port)));
  metrics.push(...(await fanoutSuite(port)));
  metrics.push(...(await memorySuite(port)));
} finally {
  await stop(child, port);
}
metrics.push(...(await nagleSuite()));
metrics.push(...microSuite());
const env = captureEnv();
if (option("--out")) writeResult(option("--out"), { suite: "server", mode, env, metrics });
else console.log(JSON.stringify(metrics, null, 2));
process.exit(0);

#!/usr/bin/env node
// Benchmark runner: starts every app, checks conformance, then measures each scenario in rounds. Within a round every
// app is measured once (the order rotates), so slow drift of the machine hits all apps alike. Called by scripts/bench.sh.
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { summarize, median, parseWrk } from "./stats.mjs";
import { check } from "./conformance.mjs";
import { runFanout } from "./ws_fanout.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");
const appsDir = path.join(root, "benchmark", "apps");
const manifest = JSON.parse(fs.readFileSync(path.join(appsDir, "manifest.json"), "utf8"));

const argv = process.argv.slice(2);
const cmd = argv[0] && !argv[0].startsWith("-") ? argv.shift() : "run";
const opts = {
  apps: null, scenarios: null, runs: 5, duration: 10, warmup: 3, connections: 64, threads: 2,
  wsClients: 50, wsSenders: 4, out: path.join(root, "benchmark", "results"), force: false, maxLoad: 0.5,
  maxBusyPct: 10, serverCpus: process.env.BENCH_SERVER_CPUS || null, loadCpus: process.env.BENCH_LOAD_CPUS || null,
  basePort: 3100, label: "", requireAll: false, db: path.join(root, "benchmark", "db", "bench.sqlite3"), json: false,
};
const flagTypes = { "--apps": "list", "--scenarios": "list", "--runs": "int", "--duration": "num", "--warmup": "num", "--connections": "int", "--threads": "int", "--ws-clients": "int", "--ws-senders": "int", "--out": "str", "--max-load": "num", "--max-busy": "num", "--server-cpus": "str", "--load-cpus": "str", "--base-port": "int", "--label": "str", "--db": "str" };
const keyOf = (f) => f.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
for (let i = 0; i < argv.length; i++) {
  const f = argv[i];
  if (f === "--force") opts.force = true;
  else if (f === "--require-all") opts.requireAll = true;
  else if (f === "--json") opts.json = true;
  else if (flagTypes[f]) {
    const v = argv[++i];
    if (v === undefined) die(`${f} needs a value`);
    const t = flagTypes[f];
    opts[keyOf(f)] = t === "list" ? v.split(",").filter(Boolean) : t === "int" ? parseInt(v, 10) : t === "num" ? parseFloat(v) : v;
    if ((t === "int" || t === "num") && Number.isNaN(opts[keyOf(f)])) die(`${f} needs a number`);
  } else die(`unknown option ${f}`);
}
if (opts.runs < 1) die("--runs must be at least 1");
if (opts.runs < 5) console.error(`warning: ${opts.runs} run(s); use at least 5 for a median and a spread you can trust`);

function die(msg) { console.error(msg); process.exit(2); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Output of a command, or null when it cannot be run (wrk exits 1 for --version, so the status is not checked)
const cap = (cmdline, args) => { const r = spawnSync(cmdline, args, { encoding: "utf8" }); return r.error ? null : (r.stdout + r.stderr).trim() || null; };

// ---------- environment ----------
function readFile(p) { try { return fs.readFileSync(p, "utf8"); } catch { return null; } }

export function environment() {
  const cpuinfo = readFile("/proc/cpuinfo") || "";
  const model = /model name\s*:\s*(.+)/.exec(cpuinfo)?.[1] || os.cpus()[0]?.model || "unknown";
  const meminfo = readFile("/proc/meminfo") || "";
  const crystal = process.env.BENCH_CRYSTAL || "crystal";
  const shards = {};
  for (const app of manifest.apps) {
    const lock = readFile(path.join(appsDir, app.dir, "shard.lock"));
    if (!lock || shards[app.dir]) continue;
    shards[app.dir] = [...lock.matchAll(/^ {2}(\S+):\n(?: {4}.*\n)*? {4}(?:git|path): .*\n(?: {4}.*\n)*? {4}version: (\S+)/gm)].map((m) => `${m[1]} ${m[2]}`);
  }
  return {
    date: new Date().toISOString(),
    kernel: `${os.type()} ${os.release()}`,
    cpu: model.trim(), cpus: os.cpus().length,
    memory_mb: Math.round(os.totalmem() / 1048576),
    swap_mb: Math.round((parseInt(/SwapTotal:\s+(\d+)/.exec(meminfo)?.[1] || "0", 10)) / 1024),
    governor: readFile("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")?.trim() || "unknown (not exposed)",
    hypervisor: /hypervisor/.test(cpuinfo) ? "yes (virtualised: expect noise)" : "no",
    loadavg: os.loadavg().map((x) => +x.toFixed(2)),
    container: fs.existsSync("/.dockerenv") ? "docker" : fs.existsSync("/run/.containerenv") ? "container" : "no",
    crystal: cap(crystal, ["--version"])?.split("\n").slice(0, 2).join(" | ") || "not found",
    wrk: (cap("wrk", ["--version"]) || "not found").split("\n")[0],
    node: process.version,
    git: cap("git", ["-C", root, "rev-parse", "--short", "HEAD"]) + (cap("git", ["-C", root, "status", "--porcelain", "--untracked-files=no"]) ? " (dirty)" : ""),
    shards,
  };
}

function printEnvironment(env) {
  console.error("== environment");
  for (const [k, v] of Object.entries(env)) {
    if (k === "shards") { for (const [d, list] of Object.entries(v)) console.error(`  shards ${d}: ${list.join(", ")}`); }
    else console.error(`  ${k}: ${Array.isArray(v) ? v.join(" ") : v}`);
  }
}

// ---------- quiet box ----------
const NOISY = new Set(["crystal", "shards", "ameba", "cc", "cc1", "cc1plus", "gcc", "clang", "ld", "ld.lld", "lld", "llc", "opt", "make", "cargo", "rustc", "wrk", "oha", "ab", "hey", "playwright", "chrome", "chromium"]);

function cpuBusyPct(ms) {
  const read = () => { const l = (readFile("/proc/stat") || "").split("\n")[0].split(/\s+/).slice(1).map(Number); return { idle: l[3] + (l[4] || 0), total: l.reduce((a, b) => a + b, 0) }; };
  return new Promise((resolve) => { const a = read(); setTimeout(() => { const b = read(); resolve(b.total === a.total ? 0 : (1 - (b.idle - a.idle) / (b.total - a.total)) * 100); }, ms); });
}

function otherNoisyProcesses() {
  const mine = new Set([process.pid, process.ppid]);
  const found = [];
  let pids = [];
  try { pids = fs.readdirSync("/proc").filter((d) => /^\d+$/.test(d)); } catch { return found; }
  for (const pid of pids) {
    if (mine.has(+pid)) continue;
    const comm = (readFile(`/proc/${pid}/comm`) || "").trim();
    if (NOISY.has(comm)) found.push(`${comm}(${pid})`);
  }
  return found;
}

async function assertQuiet() {
  const problems = [];
  const load = os.loadavg()[0];
  if (load > opts.maxLoad) problems.push(`1-minute load average ${load.toFixed(2)} > ${opts.maxLoad}`);
  const busy = await cpuBusyPct(2000);
  if (busy > opts.maxBusyPct) problems.push(`CPU ${busy.toFixed(0)}% busy over the last 2 s (limit ${opts.maxBusyPct}%)`);
  const others = otherNoisyProcesses();
  if (others.length) problems.push(`other processes that disturb a benchmark are running: ${others.slice(0, 8).join(", ")}`);
  return { problems, load, busy };
}

// ---------- CPU pinning ----------
function cpuSets() {
  const n = os.cpus().length;
  let server = opts.serverCpus, load = opts.loadCpus;
  if (!server && !load && n >= 4) { const half = n >> 1; server = `0-${half - 1}`; load = `${half}-${n - 1}`; }
  const haveTaskset = spawnSync("taskset", ["--version"]).status === 0;
  if (!haveTaskset || (!server && !load)) return { server: null, load: null, note: haveTaskset ? "fewer than 4 CPUs and no --server-cpus/--load-cpus: not pinned" : "taskset not installed: not pinned" };
  return { server, load, note: `server on CPUs ${server}, load generators on CPUs ${load}` };
}
const pin = (cpus, cmdline, args) => (cpus ? ["taskset", ["-c", cpus, cmdline, ...args]] : [cmdline, args]);

// ---------- servers ----------
function appList() {
  const wanted = opts.apps;
  return manifest.apps.filter((a) => (wanted ? wanted.includes(a.name) : a.default !== false));
}

function binaryOf(app) { return path.join(appsDir, app.dir, "bin", app.name); }

async function startServer(app, port, cpus) {
  const [c, args] = pin(cpus.server, binaryOf(app), []);
  const t0 = performance.now();
  const child = spawn(c, args, { env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", BENCH_DB: opts.db, CRYSTAL_ENV: "production" }, stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (d) => { stderr = (stderr + d).slice(-2000); });
  let exited = null;
  child.on("exit", (code, sig) => { exited = { code, sig }; });
  for (;;) {
    if (exited) throw new Error(`exited during startup (${JSON.stringify(exited)}): ${stderr.trim().split("\n").slice(-3).join(" / ")}`);
    if (performance.now() - t0 > 30000) { child.kill("SIGKILL"); throw new Error("did not answer /plaintext within 30 s"); }
    try { const r = await fetch(`http://127.0.0.1:${port}/plaintext`); await r.arrayBuffer(); if (r.status === 200) break; } catch {}
    await sleep(5);
  }
  const startup_ms = performance.now() - t0;
  // taskset execs the server, so the child pid is the server pid
  return { child, pid: child.pid, port, startup_ms, isExited: () => exited !== null };
}

function rssKb(pid) {
  const s = readFile(`/proc/${pid}/status`) || "";
  const get = (k) => parseInt(new RegExp(`${k}:\\s+(\\d+)`).exec(s)?.[1] || "0", 10);
  return { rss_kb: get("VmRSS"), peak_rss_kb: get("VmHWM") };
}

async function stopServer(srv) {
  if (srv.isExited()) return;
  srv.child.kill("SIGTERM");
  for (let i = 0; i < 50 && !srv.isExited(); i++) await sleep(100);
  if (!srv.isExited()) srv.child.kill("SIGKILL");
}

// ---------- measurement ----------
function wrkRun(scenario, port, seconds, cpus) {
  const url = `http://127.0.0.1:${port}${scenario.path}`;
  const args = ["-t", String(opts.threads), "-c", String(opts.connections), "-d", `${seconds}s`, "--timeout", "5s", "--latency"];
  if (scenario.script) args.push("-s", path.join(here, scenario.script));
  args.push(url);
  const [c, a] = pin(cpus.load, "wrk", args);
  return new Promise((resolve, reject) => {
    const p = spawn(c, a, { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (out += d));
    p.on("close", (code) => { if (code !== 0) return reject(new Error(`wrk exited ${code}: ${out.slice(-300)}`)); try { resolve(parseWrk(out)); } catch (e) { reject(e); } });
  });
}

async function measure(scenario, srv, seconds, cpus) {
  if (scenario.kind === "websocket") {
    // the node driver is pinned with the load generators when taskset is available: re-exec is avoided, see docs
    return runFanout({ url: `ws://127.0.0.1:${srv.port}${scenario.path}`, clients: opts.wsClients, senders: opts.wsSenders, duration: seconds });
  }
  return wrkRun(scenario, srv.port, seconds, cpus);
}

function aggregate(runs) {
  const col = (k) => runs.map((r) => r[k]);
  return {
    runs: runs.length,
    rps: summarize(col("rps")),
    p50_ms: median(col("p50_ms")), p99_ms: median(col("p99_ms")), p99_ms_worst: Math.max(...col("p99_ms")),
    non2xx: runs.reduce((a, r) => a + r.non2xx, 0), socket_errors: runs.reduce((a, r) => a + r.socket_errors, 0),
    extra: runs[0].driver_cpu_pct !== undefined ? { driver_cpu_pct_median: median(col("driver_cpu_pct")), round_p50_ms: median(col("round_p50_ms")), round_p99_ms: median(col("round_p99_ms")) } : undefined,
    samples: runs,
  };
}

// ---------- report ----------
const fmt = (x, d = 0) => (Number.isFinite(x) ? x.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d }) : "n/a");

export function markdown(result) {
  const L = [];
  L.push(`# Benchmark results (${result.environment.date})`, "");
  L.push("Same-session numbers from one machine. Read them as relative to each other and never compare them across machines or sessions; see docs/explanation/benchmarks.md.", "");
  L.push("## Environment", "");
  for (const [k, v] of Object.entries(result.environment)) { if (k !== "shards") L.push(`- ${k}: ${Array.isArray(v) ? v.join(" ") : v}`); }
  L.push(`- pinning: ${result.config.pinning}`, `- load: wrk ${result.config.threads} threads, ${result.config.connections} connections, ${result.config.duration}s per run, ${result.config.warmup}s warmup, ${result.config.runs} runs; websocket ${result.config.ws_clients} clients, ${result.config.ws_senders} senders`, "");
  L.push("## Apps", "", "| app | stack | startup ms | idle RSS MiB | status |", "|---|---|---:|---:|---|");
  for (const a of result.apps) L.push(`| ${a.name} | ${a.stack} | ${a.startup_ms ? fmt(a.startup_ms) : ""} | ${a.idle_rss_kb ? fmt(a.idle_rss_kb / 1024, 1) : ""} | ${a.status} |`);
  L.push("");
  for (const sc of result.scenarios) {
    L.push(`## ${sc.name}`, "");
    const unit = sc.name === "websocket" ? "deliveries/s" : "req/s";
    L.push(`| app | ${unit} median | min | max | rsd % | p50 ms | p99 ms (median / worst run) | RSS MiB (peak so far) | errors | % of baseline |`, "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|");
    const base = sc.results.find((r) => r.app === "baseline");
    for (const r of sc.results) {
      if (r.skipped) { L.push(`| ${r.app} | skipped: ${r.skipped} | | | | | | | | |`); continue; }
      const rel = base && !base.skipped ? `${fmt((r.rps.median / base.rps.median) * 100, 0)}` : "";
      L.push(`| ${r.app} | ${fmt(r.rps.median)} | ${fmt(r.rps.min)} | ${fmt(r.rps.max)} | ${fmt(r.rps.rsd_pct, 1)} | ${fmt(r.p50_ms, 2)} | ${fmt(r.p99_ms, 2)} / ${fmt(r.p99_ms_worst, 2)} | ${fmt(r.peak_rss_kb / 1024, 1)} | ${r.non2xx + r.socket_errors} | ${rel} |`);
    }
    L.push("");
  }
  L.push("An rsd above 5 % means the repetitions disagree: the machine was noisy and the row is not a measurement to quote.", "");
  return L.join("\n");
}

// ---------- main ----------
async function main() {
  if (cmd === "plan") { for (const a of appList()) console.log([a.name, a.dir, a.flags.join(" ")].join("\t")); return; }
  const env = environment();
  printEnvironment(env);
  if (cmd === "env") return;
  if (!["run", "conformance"].includes(cmd)) die(`unknown command ${cmd} (run, conformance, env, plan)`);

  if (cmd === "run") {
    const q = await assertQuiet();
    if (q.problems.length) {
      const msg = `the machine is not quiet:\n  - ${q.problems.join("\n  - ")}`;
      if (!opts.force) { console.error(`REFUSING to run: ${msg}\nStop the other work or pass --force (the result is then marked noisy).`); process.exit(3); }
      console.error(`WARNING (--force): ${msg}`);
    }
    env.noisy = q.problems;
  }

  if (!fs.existsSync(opts.db)) die(`no database at ${opts.db}: run benchmark/db/seed.sh`);
  const cpus = cpuSets();
  console.error(`== pinning: ${cpus.note}`);
  if (cpus.load) spawnSync("taskset", ["-cp", cpus.load, String(process.pid)]); // the node WebSocket driver runs in this process
  const scenarios = manifest.scenarios.filter((s) => !opts.scenarios || opts.scenarios.includes(s.name));
  if (opts.scenarios) for (const n of opts.scenarios) if (!manifest.scenarios.some((s) => s.name === n)) die(`unknown scenario ${n}`);

  const apps = [];
  let port = opts.basePort;
  let failed = false;
  for (const app of appList()) {
    const entry = { name: app.name, stack: app.stack, websocket: app.websocket, status: "ok" };
    apps.push(entry);
    if (!fs.existsSync(binaryOf(app))) { entry.status = `skipped: not built (${path.relative(root, binaryOf(app))})`; console.error(`SKIP ${app.name}: ${entry.status}`); failed ||= opts.requireAll; continue; }
    try {
      entry.server = await startServer(app, port++, cpus);
      entry.startup_ms = entry.server.startup_ms;
    } catch (e) { entry.status = `skipped: ${e.message}`; console.error(`SKIP ${app.name}: ${entry.status}`); failed ||= opts.requireAll; continue; }
    const { failures } = await check(`http://127.0.0.1:${entry.server.port}`, { ws: app.websocket });
    if (failures.length) {
      entry.status = `skipped: not conformant (${failures.length} difference(s))`;
      entry.conformance = failures;
      console.error(`FAIL ${app.name}: ${failures.length} conformance difference(s)`);
      for (const f of failures.slice(0, 5)) console.error(`  ${f.scenario} ${f.path}: ${f.what}`);
      await stopServer(entry.server); entry.server = null; failed ||= opts.requireAll || cmd === "conformance";
    } else console.error(`ok   ${app.name}: conformant`);
  }
  const live = apps.filter((a) => a.server);
  if (cmd === "conformance") { for (const a of live) await stopServer(a.server); process.exit(failed || live.length === 0 ? 1 : 0); }
  if (failed) { for (const a of live) await stopServer(a.server); die("--require-all: an app was skipped"); }
  if (!live.length) die("no app could be started");
  await sleep(500);
  for (const a of live) a.idle_rss_kb = rssKb(a.server.pid).rss_kb;

  const result = { environment: env, config: { runs: opts.runs, duration: opts.duration, warmup: opts.warmup, connections: opts.connections, threads: opts.threads, ws_clients: opts.wsClients, ws_senders: opts.wsSenders, pinning: cpus.note, label: opts.label }, apps: [], scenarios: [] };
  try {
    for (const sc of scenarios) {
      console.error(`== ${sc.name}`);
      const eligible = live.filter((a) => sc.kind !== "websocket" || a.websocket);
      const samples = new Map(eligible.map((a) => [a.name, []]));
      // warmup: one unrecorded run per app
      for (const a of eligible) { try { await measure(sc, a.server, opts.warmup, cpus); } catch (e) { console.error(`  warmup ${a.name}: ${e.message}`); } }
      for (let rep = 0; rep < opts.runs; rep++) {
        const order = eligible.map((_, i) => eligible[(i + rep) % eligible.length]);
        for (const a of order) {
          try {
            const r = await measure(sc, a.server, opts.duration, cpus);
            samples.get(a.name).push(r);
            console.error(`  run ${rep + 1}/${opts.runs} ${a.name.padEnd(10)} ${fmt(r.rps)} /s  p99 ${fmt(r.p99_ms, 2)} ms${r.non2xx + r.socket_errors ? `  ERRORS ${r.non2xx + r.socket_errors}` : ""}`);
          } catch (e) { console.error(`  run ${rep + 1}/${opts.runs} ${a.name}: ${e.message}`); }
          await sleep(300);
        }
      }
      const rows = [];
      for (const a of apps) {
        if (!a.server) { rows.push({ app: a.name, skipped: a.status.replace(/^skipped: /, "") }); continue; }
        if (!eligible.includes(a)) { rows.push({ app: a.name, skipped: "no WebSocket support" }); continue; }
        const runs = samples.get(a.name);
        if (!runs.length) { rows.push({ app: a.name, skipped: "every run failed" }); continue; }
        rows.push({ app: a.name, ...aggregate(runs), ...rssKb(a.server.pid) });
      }
      result.scenarios.push({ name: sc.name, kind: sc.kind, path: sc.path, results: rows });
    }
  } finally {
    result.apps = apps.map(({ server, ...rest }) => rest);
    for (const a of live) await stopServer(a.server);
  }
  fs.mkdirSync(opts.out, { recursive: true });
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..*/, "Z");
  const file = path.join(opts.out, `bench-${stamp}${opts.label ? "-" + opts.label.replace(/[^\w.-]/g, "_") : ""}.json`);
  fs.writeFileSync(file, JSON.stringify(result, null, 2));
  fs.writeFileSync(file.replace(/\.json$/, ".md"), markdown(result));
  console.error(`== done. load average at end: ${os.loadavg().map((x) => x.toFixed(2)).join(" ")}`);
  console.log(file);
}

if (import.meta.url === `file://${process.argv[1]}`) main().then(() => process.exit(0), (e) => { console.error(e.stack || e); process.exit(1); });

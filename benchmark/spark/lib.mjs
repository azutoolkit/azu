// Shared by the Spark benchmark scripts: statistics, environment capture, and the result file format.
//
// A result file is JSON: { schema, tool, mode, created, env, metrics: [...] }. A metric is
// { id, unit, better, median, p95, cv, n, extra? }: `better` says which direction is an improvement
// ("lower" or "higher"), `cv` is the coefficient of variation of the per-repetition medians (the noise
// of that measurement), `n` the number of samples behind the median.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import os from "node:os";

export const SCHEMA = 1;

export function median(values) {
  return quantile(values, 0.5);
}

/** Linear-interpolated quantile of *values* (q in 0..1). */
export function quantile(values, q) {
  if (values.length === 0) return NaN;
  const sorted = [...values].sort((a, b) => a - b);
  const position = (sorted.length - 1) * q;
  const low = Math.floor(position);
  const high = Math.ceil(position);
  return sorted[low] + (sorted[high] - sorted[low]) * (position - low);
}

export function mean(values) {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

/** Coefficient of variation: standard deviation over mean (0 for fewer than two values). */
export function cv(values) {
  if (values.length < 2) return 0;
  const m = mean(values);
  if (m === 0) return 0;
  const variance = values.reduce((sum, value) => sum + (value - m) ** 2, 0) / (values.length - 1);
  return Math.sqrt(variance) / Math.abs(m);
}

const round = (value, digits = 4) => (Number.isFinite(value) ? Number(value.toPrecision(digits)) : value);

/**
 * Builds a metric from *reps*, an array (one per repetition) of arrays of samples. The median and p95
 * are over all samples; `cv` is over the repetition medians, so a drifting box shows up as noise.
 */
export function metric(id, unit, reps, { better = "lower", extra, floor } = {}) {
  const all = reps.flat();
  const repMedians = reps.filter((rep) => rep.length > 0).map(median);
  const result = { id, unit, better, median: round(median(all)), p95: round(quantile(all, 0.95)), cv: round(cv(repMedians), 3), n: all.length };
  if (extra) result.extra = extra;
  if (floor) result.floor = floor;
  return result;
}

/** A metric that is a single number (a size, a count): no noise. */
export function scalar(id, unit, value, { better = "lower", extra } = {}) {
  const result = { id, unit, better, median: value, p95: value, cv: 0, n: 1 };
  if (extra) result.extra = extra;
  return result;
}

function run(command, args) {
  try {
    return execFileSync(command, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null;
  }
}

/** What the numbers were measured on. Anything that is not available is null, never an error. */
export function captureEnv({ chromium } = {}) {
  const cpus = os.cpus();
  const crystal = process.env.BENCH_CRYSTAL_VERSION || run("crystal", ["--version"])?.split("\n")[0] || null;
  return {
    cpu: cpus[0]?.model ?? null,
    cores: cpus.length,
    memory_mb: Math.round(os.totalmem() / 1048576),
    load_before: os.loadavg().map((value) => round(value, 3)),
    platform: `${os.type()} ${os.release()}`,
    node: process.version,
    chromium: chromium ?? null,
    crystal,
    git: run("git", ["rev-parse", "--short", "HEAD"]),
    git_dirty: (run("git", ["status", "--porcelain"]) ?? "") !== "",
    container: Boolean(process.env.BENCH_CONTAINER) || null,
  };
}

export function loadAverageNow() {
  return os.loadavg().map((value) => round(value, 3));
}

export function writeResult(path, { suite, mode, env, metrics }) {
  const body = { schema: SCHEMA, tool: "azu-spark-bench", suite, mode, created: new Date().toISOString(), env: { ...env, load_after: loadAverageNow() }, metrics };
  writeFileSync(path, `${JSON.stringify(body, null, 2)}\n`);
  return body;
}

export function readResult(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

/** Merges result files of several suites into one; the environment keeps the first value any suite recorded (the load average after is the last). */
export function merge(results) {
  const [first] = results;
  const env = {};
  for (const result of results) for (const [key, value] of Object.entries(result.env ?? {})) if (value !== null && value !== undefined && (key === "load_after" || !(key in env))) env[key] = value;
  return {
    schema: SCHEMA,
    tool: "azu-spark-bench",
    suite: results.map((result) => result.suite).join("+"),
    mode: first.mode,
    created: new Date().toISOString(),
    env,
    metrics: results.flatMap((result) => result.metrics),
  };
}

/** The mode knobs: "short" finishes in a couple of minutes, "full" is for a quiet machine. */
export function settings(mode) {
  return mode === "full"
    ? { reps: 15, perRep: 6, keystrokes: 1000, frames: 100000, memoryPatches: 3000, memoryReps: 5 }
    : { reps: 10, perRep: 3, keystrokes: 1000, frames: 20000, memoryPatches: 800, memoryReps: 3 };
}

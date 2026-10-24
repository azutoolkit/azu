#!/usr/bin/env node
// Diffs two Spark benchmark result files and fails when a metric got worse than a threshold.
//
//   node benchmark/spark/compare.mjs BASE.json CANDIDATE.json [options]
//
//   --threshold PCT     regression limit on medians, in percent (default 15)
//   --noise-cv RATIO    a run whose repetitions vary more than this (coefficient of variation) is "noisy" (default 0.2);
//                       it excuses only a change below 3 x its cv, a larger one still fails
//   --fail-on-noisy     a regression measured on a noisy run fails too (default: a warning)
//   --min-delta VALUE   ignore a regression whose absolute change is below VALUE, in the metric's unit (default 0)
//   --strict-missing    a metric present on one side only fails (default: listed)
//   --only PREFIX       compare the metrics whose id starts with PREFIX
//   --json              print the report as JSON
//
// Exit status: 0 no regression, 1 regression, 2 bad usage or invalid/incomparable files (NaN or missing median, schema/unit/direction mismatch, short vs full runs with different sample counts). Medians are compared, never means or minima.
// A metric may carry a `floor` (an absolute change below which it is noise, e.g. a few KB of heap).
// "Worse" follows each metric's `better` field: slower for "lower", less throughput for "higher".
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const DEFAULTS = { threshold: 15, noiseCv: 0.2, failOnNoisy: false, minDelta: 0, strictMissing: false, only: "" };

/** Percent by which *candidate* is worse than *base* (negative: better). */
const UNBOUNDED = 1e9; // stands for "from zero to something": finite, so it survives JSON

function worsening(base, candidate, better) {
  if (base.median === 0) {
    if (candidate.median === 0) return 0;
    return (candidate.median > 0) === (better === "lower") ? UNBOUNDED : -UNBOUNDED;
  }
  const change = ((candidate.median - base.median) / Math.abs(base.median)) * 100;
  return better === "higher" ? -change : change;
}

const round1 = (value) => Math.round(value * 10) / 10;

function environmentWarnings(base, candidate) {
  const a = base.env ?? {};
  const b = candidate.env ?? {};
  const warnings = [];
  const differs = (field, label) => {
    if (a[field] && b[field] && a[field] !== b[field]) warnings.push(`${label} differs: "${a[field]}" vs "${b[field]}"; the numbers are not comparable`);
  };
  differs("cpu", "cpu");
  differs("cores", "core count");
  differs("node", "node version");
  differs("chromium", "chromium version");
  if (base.mode && candidate.mode && base.mode !== candidate.mode) warnings.push(`mode differs: ${base.mode} vs ${candidate.mode}`);
  for (const [name, env] of [["base", a], ["candidate", b]]) {
    const load = env.load_before?.[0];
    if (load != null && env.cores && load > env.cores * 0.7) warnings.push(`${name} run started under load (load average ${load} on ${env.cores} cores): the box was busy, treat the numbers as indicative`);
    if (env.git_dirty) warnings.push(`${name} run was measured on a dirty working tree`);
  }
  return warnings;
}

/**
 * Compares two parsed result files. Returns { ok, rows, regressions, missing, warnings, options }.
 * A row is { id, unit, base, candidate, change, status, cv }; `change` is the percent the candidate is
 * worse (positive) or better (negative), rounded to one decimal.
 */
export function compareResults(base, candidate, options = {}) {
  const opts = { ...DEFAULTS, ...options };
  const baseById = new Map(base.metrics.map((entry) => [entry.id, entry]));
  const candidateById = new Map(candidate.metrics.map((entry) => [entry.id, entry]));
  const selected = (id) => id.startsWith(opts.only);
  const warnings = environmentWarnings(base, candidate);
  const rows = [];
  const errors = [];
  if (base.schema !== candidate.schema) errors.push(`schema differs: ${base.schema} vs ${candidate.schema}`);
  const modesDiffer = base.mode && candidate.mode && base.mode !== candidate.mode;
  for (const [id, b] of baseById) {
    const c = candidateById.get(id);
    if (!c || !selected(id)) continue;
    const bad = [["base", b], ["candidate", c]].filter(([, m]) => typeof m.median !== "number" || !Number.isFinite(m.median));
    if (bad.length) {
      errors.push(`${id}: the ${bad.map(([name]) => name).join(" and ")} median is not a finite number`);
      continue;
    }
    if (b.unit !== c.unit) { errors.push(`${id}: unit differs (${b.unit} vs ${c.unit})`); continue; }
    if ((b.better ?? "lower") !== (c.better ?? "lower")) { errors.push(`${id}: better differs (${b.better} vs ${c.better})`); continue; }
    if (modesDiffer && b.n !== c.n) {
      errors.push(`${id}: ${base.mode} and ${candidate.mode} runs took different numbers of samples (${b.n} vs ${c.n}); compare runs of the same mode (mode differs)`);
      continue;
    }
    const change = worsening(b, c, b.better ?? "lower");
    // A noisy run only excuses a change that its own spread could explain: within 3 coefficients of variation.
    const spread = Math.max(b.cv ?? 0, c.cv ?? 0);
    const noisy = spread > opts.noiseCv && change < 3 * spread * 100;
    let status = "ok";
    if (change > opts.threshold && Math.abs(c.median - b.median) >= Math.max(opts.minDelta, b.floor ?? 0)) {
      status = noisy ? "noisy" : "regression";
    } else if (change < -opts.threshold) {
      status = "improved";
    }
    rows.push({ id, unit: b.unit, better: b.better ?? "lower", base: b.median, candidate: c.median, change: round1(change), cv: Math.max(b.cv ?? 0, c.cv ?? 0), status });
  }
  const missing = [...baseById.keys()].filter((id) => selected(id) && !candidateById.has(id)).concat([...candidateById.keys()].filter((id) => selected(id) && !baseById.has(id)));
  const regressions = rows.filter((row) => row.status === "regression");
  const noisy = rows.filter((row) => row.status === "noisy");
  for (const row of noisy) warnings.push(`${row.id} looks ${row.change}% worse but the run was noisy (cv ${row.cv} > ${opts.noiseCv}); rerun on a quiet machine before believing it`);
  if (missing.length) warnings.push(`${missing.length} metric(s) exist on one side only: ${missing.join(", ")}`);
  const ok = errors.length === 0 && regressions.length === 0 && !(opts.failOnNoisy && noisy.length > 0) && !(opts.strictMissing && missing.length > 0);
  return { ok, rows, regressions, missing, errors, warnings, options: opts };
}

const pad = (text, width) => String(text).padEnd(width);

export function formatReport(report) {
  const width = Math.max(6, ...report.rows.map((row) => row.id.length));
  const lines = [];
  const loud = report.warnings.filter((warning) => /differs/.test(warning));
  if (loud.length) lines.push(`WARNING: NOT COMPARABLE, ${loud.join("; ")}`, "");
  for (const error of report.errors) lines.push(`ERROR: ${error}`);
  if (report.errors.length) lines.push("");
  lines.push(`${pad("metric", width)}  ${pad("base", 12)} ${pad("candidate", 12)} ${pad("change", 9)} verdict`);
  for (const row of report.rows) {
    const sign = row.change > 0 ? "+" : "";
    const change = `${sign}${row.change.toFixed(1)}%`;
    const verdict = { regression: "REGRESSION", noisy: "noisy (warning)", improved: "improved", ok: "ok" }[row.status];
    lines.push(`${pad(row.id, width)}  ${pad(`${row.base} ${row.unit}`, 12)} ${pad(`${row.candidate} ${row.unit}`, 12)} ${pad(change, 9)} ${verdict}`);
  }
  lines.push("", "change is how much worse the candidate is (positive = worse, in the direction the metric prefers); medians only.");
  for (const warning of report.warnings) lines.push(`WARNING: ${warning}`);
  if (report.errors.length) {
    lines.push(`INVALID: ${report.errors.length} error(s); nothing can be concluded`);
    return lines.join("\n");
  }
  const { threshold } = report.options;
  lines.push(report.ok ? `OK: no regression above ${threshold}%` : `FAIL: ${report.regressions.length} regression(s) above ${threshold}%`);
  return lines.join("\n");
}

function parseArgs(argv) {
  const options = {};
  const files = [];
  const value = (name, i) => {
    if (i + 1 >= argv.length) throw new Error(`${name} needs a value`);
    return argv[i + 1];
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--threshold") options.threshold = Number(value(arg, i++));
    else if (arg === "--noise-cv") options.noiseCv = Number(value(arg, i++));
    else if (arg === "--min-delta") options.minDelta = Number(value(arg, i++));
    else if (arg === "--only") options.only = value(arg, i++);
    else if (arg === "--fail-on-noisy") options.failOnNoisy = true;
    else if (arg === "--strict-missing") options.strictMissing = true;
    else if (arg === "--json") options.json = true;
    else if (arg.startsWith("--")) throw new Error(`unknown option ${arg}`);
    else files.push(arg);
  }
  for (const key of ["threshold", "noiseCv", "minDelta"]) {
    if (key in options && !(options[key] >= 0)) throw new Error(`--${key} needs a non-negative number`);
  }
  if (files.length !== 2) throw new Error("usage: compare.mjs BASE.json CANDIDATE.json [options]");
  return { files, options };
}

function main(argv) {
  let parsed;
  let results;
  try {
    parsed = parseArgs(argv);
    results = parsed.files.map((file) => JSON.parse(readFileSync(file, "utf8")));
    for (const result of results) if (!Array.isArray(result.metrics)) throw new Error("not a result file: no metrics");
  } catch (error) {
    console.error(error.message);
    return 2;
  }
  const { json, ...options } = parsed.options;
  const report = compareResults(results[0], results[1], options);
  console.log(json ? JSON.stringify(report, null, 2) : formatReport(report));
  if (report.errors.length) return 2;
  return report.ok ? 0 : 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exit(main(process.argv.slice(2)));

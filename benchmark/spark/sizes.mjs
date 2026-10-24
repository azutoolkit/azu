#!/usr/bin/env node
// Artifact size over time: raw, gzip -9 and brotli bytes of the shipped Spark client at every commit
// that changed it, so a size regression is visible next to the slice that caused it.
//
//   node benchmark/spark/sizes.mjs [--out FILE.json] [--table FILE.md] [--mode short|full]
//
// Needs the git history (a shallow clone lists only the commits it has). Sizes are exact and need no
// repetitions: the metrics have no noise.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";
import { fileURLToPath } from "node:url";
import { captureEnv, scalar, writeResult } from "./lib.mjs";

export const ARTIFACT = "src/azu/spark/client/azu_spark.js";

const root = fileURLToPath(new URL("../..", import.meta.url));
const git = (...args) => execFileSync("git", ["-C", root, ...args], { encoding: "buffer", maxBuffer: 64 * 1024 * 1024 });

export function sizesOf(bytes) {
  return {
    raw: bytes.length,
    gzip: gzipSync(bytes, { level: 9 }).length,
    brotli: brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length,
  };
}

/** One entry per commit that touched the artifact, oldest first. */
export function history() {
  const log = git("log", "--reverse", "--format=%h%x09%cs%x09%s", "--", ARTIFACT).toString("utf8").trim();
  if (!log) return [];
  return log.split("\n").map((line) => {
    const [sha, date, ...subject] = line.split("\t");
    let bytes;
    try {
      bytes = git("show", `${sha}:${ARTIFACT}`);
    } catch {
      return null; // the commit deleted it
    }
    return { sha, date, subject: subject.join("\t"), ...sizesOf(bytes) };
  }).filter(Boolean);
}

export function markdownTable(entries) {
  const rows = entries.map((entry, i) => {
    const before = entries[i - 1];
    const delta = before ? `${entry.gzip - before.gzip >= 0 ? "+" : ""}${entry.gzip - before.gzip}` : "";
    return `| ${entry.sha} | ${entry.date} | ${entry.subject.replace(/\|/g, "/").slice(0, 70)} | ${entry.raw} | ${entry.gzip} | ${entry.brotli} | ${delta} |`;
  });
  return ["| commit | date | subject | raw B | gzip -9 B | brotli B | gzip delta |", "|---|---|---|---:|---:|---:|---:|", ...rows].join("\n");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const option = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : null);
  const entries = history();
  const table = markdownTable(entries);
  console.log(table);
  if (option("--table")) writeFileSync(option("--table"), `${table}\n`);
  const head = entries.at(-1);
  const current = sizesOf(readFileSync(`${root}/${ARTIFACT}`));
  const metrics = Object.entries(current).map(([kind, value]) => scalar(`size.client.${kind}`, "bytes", value, { extra: kind === "raw" ? { history: entries } : undefined }));
  if (option("--out")) writeResult(option("--out"), { suite: "sizes", mode: option("--mode") ?? "short", env: captureEnv(), metrics });
  if (!head) process.exitCode = 1;
}

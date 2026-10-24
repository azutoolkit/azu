#!/usr/bin/env node
// Prints a result file as Markdown tables: node report.mjs RESULT.json
//
// The client patch, keystroke and memory metrics are grouped by case with the three arms side by side
// (naive innerHTML, the engine before slice 3, the current engine); everything else is listed as is.
import { readResult } from "./lib.mjs";

export function report(result) {
  const lines = [];
  const env = result.env ?? {};
  lines.push(`Mode ${result.mode}, ${result.created}. CPU ${env.cpu} x${env.cores}, node ${env.node}, ${env.chromium ? `chromium ${env.chromium}, ` : ""}${env.crystal ?? "crystal n/a"}, load average before ${env.load_before?.join(" ")} after ${env.load_after?.join(" ") ?? "n/a"}.`, "");
  const arms = ["naive", "prev", "current"];
  const grouped = new Map();
  const rest = [];
  for (const m of result.metrics) {
    const match = m.id.match(/^(client\.(?:patch|keystrokes\.[a-z0-9]+|memory\.[a-z_0-9]+|frame))\.?(.*?)\.?(naive|prev|current|json_parse_only)(\.[a-z]+)?$/);
    const parts = m.id.split(".");
    const arm = parts.find((p) => arms.includes(p));
    if (m.id.startsWith("client.") && arm && !m.id.startsWith("client.frame")) {
      const key = parts.filter((p) => p !== arm).join(".");
      if (!grouped.has(key)) grouped.set(key, {});
      grouped.get(key)[arm] = m;
    } else rest.push(m);
    void match;
  }
  const cell = (m) => (m ? `${m.median} (p95 ${m.p95}, cv ${m.cv})` : "n/a");
  lines.push("| case | unit | naive | prev | current | current / prev | current / naive |", "|---|---|---|---|---|---:|---:|");
  for (const [key, row] of grouped) {
    const unit = (row.current ?? row.prev ?? row.naive).unit;
    const ratioMeaningful = /patch|keystrokes/.test(key);
    const ratio = (a, b) => (ratioMeaningful && a && b && b.median ? `${(a.median / b.median).toFixed(2)}x` : "");
    lines.push(`| ${key} | ${unit} | ${cell(row.naive)} | ${cell(row.prev)} | ${cell(row.current)} | ${ratio(row.current, row.prev)} | ${ratio(row.current, row.naive)} |`);
    if (row.current?.extra?.focus_kept !== undefined) lines.push(`| ${key} focus kept | ratio | ${row.naive?.extra?.focus_kept} | ${row.prev?.extra?.focus_kept} | ${row.current.extra.focus_kept} | | |`);
  }
  lines.push("", "| metric | unit | median | p95 | cv | n |", "|---|---|---:|---:|---:|---:|");
  for (const m of rest) lines.push(`| ${m.id} | ${m.unit} | ${m.median} | ${m.p95} | ${m.cv} | ${m.n} |`);
  return lines.join("\n");
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop())) {
  if (!process.argv[2]) { console.error("usage: report.mjs RESULT.json"); process.exit(2); }
  console.log(report(readResult(process.argv[2])));
}

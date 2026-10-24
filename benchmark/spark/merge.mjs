#!/usr/bin/env node
// Merges the result files of the suites into one: node merge.mjs OUT.json IN1.json IN2.json ...
import { writeFileSync } from "node:fs";
import { merge, readResult } from "./lib.mjs";

const [out, ...inputs] = process.argv.slice(2);
if (!out || inputs.length === 0) {
  console.error("usage: merge.mjs OUT.json IN.json...");
  process.exit(2);
}
writeFileSync(out, `${JSON.stringify(merge(inputs.map(readResult)), null, 2)}\n`);
console.log(`wrote ${out}`);

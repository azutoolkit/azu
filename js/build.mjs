// Builds the shipped Spark client from the readable source.
//
//   node build.mjs           write ../src/azu/spark/client/azu_spark.js
//   node build.mjs --check   build in memory and fail when the checked-in script differs
//
// The output is a minified ES2022 IIFE whose first line records the SHA-256 of azu-spark.js; a
// Crystal spec compares that hash with the source, so a script that was not rebuilt after an edit
// fails `crystal spec` without node. esbuild is pinned in package.json/package-lock.json, which
// keeps the output reproducible. Application developers never run this: the result is checked in.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
const source = resolve(here, "azu-spark.js");
const artifact = resolve(here, "../src/azu/spark/client/azu_spark.js");

export async function render() {
  const sha = createHash("sha256").update(readFileSync(source)).digest("hex");
  const { outputFiles } = await build({
    entryPoints: [source],
    bundle: true,
    minify: true,
    format: "iife",
    target: "es2022",
    legalComments: "none",
    write: false,
    outfile: "azu_spark.js",
  });
  return `/*! azu-spark src-sha256:${sha} (built from js/azu-spark.js by js/build.mjs; do not edit) */\n${outputFiles[0].text}`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const built = await render();
  if (process.argv.includes("--check")) {
    let current = "";
    try { current = readFileSync(artifact, "utf8"); } catch { /* missing counts as different */ }
    if (current !== built) {
      console.error("src/azu/spark/client/azu_spark.js is stale: run `npm run build` in js/ and commit the result");
      process.exit(1);
    }
    console.log("azu_spark.js is up to date");
  } else {
    writeFileSync(artifact, built);
    console.log(`wrote ${artifact} (${built.length} bytes)`);
  }
}

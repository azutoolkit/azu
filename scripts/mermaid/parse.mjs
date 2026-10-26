// Parses every ```mermaid block of the Markdown files given as arguments with Mermaid's own parser, so a diagram
// that GitBook would show as an error fails CI instead. Exits 1 on the first file with a block that does not parse.
//
//   node scripts/mermaid/parse.mjs $(git ls-files 'docs/*.md' 'docs/**/*.md')
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>");
globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.DOMParser = dom.window.DOMParser;
globalThis.Element = dom.window.Element;

const { default: mermaid } = await import("mermaid");
mermaid.initialize({ startOnLoad: false });

let blocks = 0;
let failed = 0;
for (const file of process.argv.slice(2)) {
  const lines = readFileSync(file, "utf8").split("\n");
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() !== "```mermaid") continue;
    const start = i + 1;
    const end = lines.findIndex((line, j) => j > i && line.trim() === "```");
    if (end === -1) {
      failed++;
      console.log(`${file}:${start}: unclosed mermaid block`);
      break;
    }
    blocks++;
    try {
      await mermaid.parse(lines.slice(start, end).join("\n"));
    } catch (error) {
      failed++;
      console.log(`${file}:${start}: ${String(error.message || error).split("\n")[0]}`);
    }
    i = end;
  }
}
console.log(`${blocks} mermaid blocks parsed, ${failed} failed`);
process.exit(failed ? 1 : 0);

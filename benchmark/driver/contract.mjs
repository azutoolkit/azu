// The benchmark contract: what every app answers. The expected bodies are computed here, independently of the
// Crystal fixtures (benchmark/apps/common/bench.cr), so a drift in either shows up in the conformance check.
export const ROUTE_COUNT = 100;
export const ITEM_COUNT = 20;
export const DB_ROWS = 1000;
export const DB_LIST_LIMIT = 20;

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

export function templateBody() {
  let li = "";
  for (let i = 1; i <= ITEM_COUNT; i++) li += `<li class="item-${i}">${esc(`Item ${i} & <co>`)} (${i * 7})</li>`;
  return `<!DOCTYPE html><html><head><title>Items</title></head><body><h1>Items</h1><ul>${li}</ul></body></html>`;
}

const row = (i) => ({ id: i, name: `item-${i}`, value: i * 3 });

// [scenario, path, status, media type, body]
export function cases() {
  const out = [
    ["plaintext", "/plaintext", 200, "text/plain", "Hello, World!"],
    ["json", "/json", 200, "application/json", JSON.stringify({ message: "Hello, World!" })],
    ["template", "/template", 200, "text/html", templateBody()],
    ["db_single", "/db/item/1", 200, "application/json", JSON.stringify(row(1))],
    ["db_single", "/db/item/1000", 200, "application/json", JSON.stringify(row(1000))],
    ["db_multi", "/db/items", 200, "application/json", JSON.stringify(Array.from({ length: DB_LIST_LIMIT }, (_, i) => row(i + 1)))],
  ];
  for (const n of [0, 1, 57, ROUTE_COUNT - 1]) {
    out.push(["routing", `/api/v1/resource${n}/42`, 200, "application/json", JSON.stringify({ route: `resource${n}`, id: "42" })]);
  }
  out.push(["routing", "/api/v1/resource57/abc", 200, "application/json", JSON.stringify({ route: "resource57", id: "abc" })]);
  return out;
}

// Paths that must not match any route: only the status is compared (error bodies differ by framework).
export const missing = [["notfound", "/api/v1/resource100/42", 404], ["notfound", "/nope", 404], ["notfound", "/db/item/1001", 404]];

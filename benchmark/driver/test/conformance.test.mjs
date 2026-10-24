import test from "node:test";
import assert from "node:assert/strict";
import { parseResponse } from "../conformance.mjs";
import { parseCpuList, foreignCpuPct, aggregate, invalidRows, markdown } from "../run.mjs";
import { summarize } from "../stats.mjs";

const head = (extra) => `HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n${extra}\r\n`;

test("parseResponse reads Content-Length bodies and counts the bytes on the wire", () => {
  const raw = Buffer.from(head("Content-Length: 5\r\n") + "hello");
  const r = parseResponse(raw, false);
  assert.equal(r.status, 200);
  assert.equal(r.body, "hello");
  assert.equal(r.chunked, false);
  assert.equal(r.bytes, raw.length);
  assert.equal(parseResponse(raw.subarray(0, raw.length - 2), false), null); // incomplete
});

test("parseResponse flags and decodes chunked bodies", () => {
  const r = parseResponse(Buffer.from(head("Transfer-Encoding: chunked\r\n") + "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"), false);
  assert.equal(r.chunked, true);
  assert.equal(r.body, "abcde");
});

test("parseCpuList expands ranges", () => {
  assert.deepEqual(parseCpuList("0-2,5"), [0, 1, 2, 5]);
  assert.deepEqual(parseCpuList("3"), [3]);
});

test("a malformed chunk size is an error result, not an endless loop", () => {
  const r = parseResponse(Buffer.from(head("Transfer-Encoding: chunked\r\n") + "zz\r\nabc\r\n0\r\n\r\n"), false);
  assert.match(r.malformed, /bad chunk size/);
});

test("duplicate Content-Length and folded headers are flagged", () => {
  const r = parseResponse(Buffer.from("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\nX-A: 1\r\n  folded\r\n\r\nhi"), false);
  assert.equal(r.duplicateContentLength, true);
  assert.equal(r.obsFold, true);
});

test("foreign CPU is what the machine used minus what our processes used", () => {
  const start = { busy: 1000, total: 4000 };
  const end = { busy: 1900, total: 8000 }; // 900 busy of 4000 jiffies
  assert.equal(foreignCpuPct(start, end, 900), 0); // all of it was ours: no bogus noise
  assert.equal(foreignCpuPct(start, end, 500), 10);
  assert.equal(foreignCpuPct(start, end, 2000), 0);
});

test("a row where every run failed is invalid and listed", () => {
  const result = { environment: { date: "x" }, config: {}, apps: [], scenarios: [{ name: "json", results: [{ app: "azu", skipped: "every run failed", invalid: true }, { app: "kemal", skipped: "no WebSocket support" }] }] };
  assert.deepEqual(invalidRows(result), ["json/azu"]);
  assert.match(markdown({ ...result, config: { pinning: "", threads: 1, connections: 1, duration: 1, warmup: 1, runs: 1, ws_clients: 1, ws_senders: 1 }, invalid_rows: invalidRows(result) }), /INVALID rows.*json\/azu/);
});

test("fewer than 3 runs have no rsd; fewer than 5 are flagged", () => {
  assert.ok(Number.isNaN(summarize([10, 20]).rsd_pct));
  const run = { rps: 10, p50_ms: 1, p99_ms: 2, requests: 100, non2xx: 0, socket_errors: 0 };
  assert.equal(aggregate([run, run]).few_runs, true);
  assert.equal(aggregate([run, run, run, run, run]).few_runs, false);
  assert.equal(aggregate([{ ...run, requests: 0 }]).invalid, true);
});

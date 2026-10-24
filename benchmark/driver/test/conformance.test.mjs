import test from "node:test";
import assert from "node:assert/strict";
import { parseResponse } from "../conformance.mjs";
import { parseCpuList } from "../run.mjs";

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

import test from "node:test";
import assert from "node:assert/strict";
import { median, stddev, rsd, summarize, parseWrk, toMs, percentile } from "../stats.mjs";
import { cases, templateBody } from "../contract.mjs";

test("median handles odd and even counts", () => {
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([4, 1, 2, 3]), 2.5);
});

test("stddev and rsd use the sample formula", () => {
  assert.equal(stddev([5]), 0);
  assert.ok(Math.abs(stddev([2, 4, 4, 4, 5, 5, 7, 9]) - 2.138089935) < 1e-6);
  assert.ok(Math.abs(rsd([10, 10, 10])) < 1e-12);
  assert.ok(Math.abs(rsd([90, 100, 110]) - 10) < 1e-9);
});

test("summarize reports min, max and the median", () => {
  const s = summarize([100, 120, 90, 110, 105]);
  assert.equal(s.median, 105);
  assert.equal(s.min, 90);
  assert.equal(s.max, 120);
  assert.equal(s.n, 5);
});

test("toMs converts every wrk unit", () => {
  assert.equal(toMs("500.00us"), 0.5);
  assert.equal(toMs("1.50ms"), 1.5);
  assert.equal(toMs("2.00s"), 2000);
  assert.throws(() => toMs("fast"));
});

const WRK = `Running 10s test @ http://127.0.0.1:3000/plaintext
  2 threads and 64 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.50ms  800.00us  20.00ms   90.00%
    Req/Sec    21.00k     1.00k   25.00k    70.00%
  Latency Distribution
     50%    1.20ms
     75%    1.80ms
     90%    2.50ms
     99%    6.00ms
  420000 requests in 10.00s, 50.00MB read
  Non-2xx or 3xx responses: 3
  Socket errors: connect 1, read 2, write 0, timeout 4
Requests/sec:  42000.50
Transfer/sec:      5.00MB
`;

test("parseWrk reads throughput, percentiles and errors", () => {
  const r = parseWrk(WRK);
  assert.equal(r.rps, 42000.5);
  assert.equal(r.p50_ms, 1.2);
  assert.equal(r.p99_ms, 6);
  assert.equal(r.requests, 420000);
  assert.equal(r.non2xx, 3);
  assert.equal(r.socket_errors, 7);
  assert.throws(() => parseWrk("nothing"));
});

test("percentile is nearest rank", () => {
  const xs = Array.from({ length: 100 }, (_, i) => i + 1);
  assert.equal(percentile(xs, 50), 50);
  assert.equal(percentile(xs, 99), 99);
  assert.equal(percentile([7], 99), 7);
});

test("the contract covers every scenario once with an escaped template", () => {
  const scenarios = new Set(cases().map((c) => c[0]));
  for (const s of ["plaintext", "json", "template", "routing", "db_single", "db_multi"]) assert.ok(scenarios.has(s), s);
  assert.match(templateBody(), /Item 1 &amp; &lt;co&gt; \(7\)/);
});

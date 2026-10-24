// The statistics and the result format the whole suite rests on.
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { cv, median, merge, metric, quantile, scalar, settings } from "../lib.mjs";

describe("statistics", () => {
  it("takes the median of odd and even counts", () => {
    assert.equal(median([3, 1, 2]), 2);
    assert.equal(median([4, 1, 3, 2]), 2.5);
  });

  it("interpolates quantiles", () => {
    assert.equal(quantile([1, 2, 3, 4, 5], 0.95), 4.8);
    assert.equal(quantile([7], 0.95), 7);
    assert.ok(Number.isNaN(quantile([], 0.5)));
  });

  it("measures noise as the coefficient of variation", () => {
    assert.equal(cv([5]), 0);
    assert.equal(cv([10, 10, 10]), 0);
    assert.ok(Math.abs(cv([9, 10, 11]) - 0.1) < 1e-9);
  });
});

describe("metric", () => {
  it("pools samples for median and p95 but measures noise across repetition medians", () => {
    const m = metric("x", "ms", [[1, 1, 1], [2, 2, 2]]);
    assert.equal(m.median, 1.5);
    assert.equal(m.n, 6);
    assert.ok(m.cv > 0.3, `the two repetitions differ by 2x, cv was ${m.cv}`);
  });

  it("carries direction, floor and extra", () => {
    const m = metric("t", "events/s", [[10]], { better: "higher", floor: 5, extra: { a: 1 } });
    assert.deepEqual([m.better, m.floor, m.extra], ["higher", 5, { a: 1 }]);
  });

  it("makes a noiseless scalar", () => {
    assert.deepEqual(scalar("s", "bytes", 42), { id: "s", unit: "bytes", better: "lower", median: 42, p95: 42, cv: 0, n: 1 });
  });
});

describe("merge and settings", () => {
  it("concatenates the metrics of several suites", () => {
    const merged = merge([
      { suite: "a", mode: "short", env: { cpu: "x" }, metrics: [scalar("a", "b", 1)] },
      { suite: "b", mode: "short", env: { cpu: "y", load_after: [1, 1, 1] }, metrics: [scalar("b", "b", 2)] },
    ]);
    assert.equal(merged.suite, "a+b");
    assert.deepEqual(merged.metrics.map((m) => m.id), ["a", "b"]);
    assert.deepEqual(merged.env.load_after, [1, 1, 1]);
    assert.equal(merged.env.cpu, "x");
  });

  it("keeps the values only one suite knows, such as the chromium and crystal versions", () => {
    const merged = merge([
      { suite: "client", mode: "short", env: { cpu: "x", chromium: "141", crystal: null }, metrics: [] },
      { suite: "server", mode: "short", env: { cpu: "x", chromium: null, crystal: "Crystal 1.22" }, metrics: [] },
    ]);
    assert.equal(merged.env.chromium, "141");
    assert.equal(merged.env.crystal, "Crystal 1.22");
  });

  it("asks for at least 10 repetitions in both modes", () => {
    assert.ok(settings("short").reps >= 10);
    assert.ok(settings("full").reps >= 10);
  });
});

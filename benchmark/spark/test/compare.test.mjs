// The compare tool must detect regressions, ignore noise, and say when a number cannot be trusted.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { compareResults, DEFAULTS, formatReport } from "../compare.mjs";

const fixture = (name) => JSON.parse(readFileSync(fileURLToPath(new URL(`./fixtures/${name}.json`, import.meta.url)), "utf8"));
const cli = (...args) =>
  spawnSync(process.execPath, [fileURLToPath(new URL("../compare.mjs", import.meta.url)), ...args], { encoding: "utf8" });
const path = (name) => fileURLToPath(new URL(`./fixtures/${name}.json`, import.meta.url));
const row = (report, id) => report.rows.find((r) => r.id === id);

describe("compareResults", () => {
  it("passes identical runs", () => {
    const report = compareResults(fixture("base"), fixture("base"));
    assert.equal(report.ok, true);
    assert.deepEqual(report.rows.map((r) => r.status), ["ok", "ok", "ok", "ok"]);
  });

  it("does not fail a change inside the default 15% threshold", () => {
    const report = compareResults(fixture("base"), fixture("within"));
    assert.equal(report.ok, true);
    assert.equal(row(report, "client.patch.reorder1000.current").status, "ok");
    assert.equal(row(report, "client.patch.reorder1000.current").change, 10);
  });

  it("detects a regression of a lower-is-better metric and reports an improvement", () => {
    const report = compareResults(fixture("base"), fixture("regressed"));
    assert.equal(report.ok, false);
    assert.equal(row(report, "client.patch.reorder1000.current").status, "regression");
    assert.equal(row(report, "client.patch.reorder1000.current").change, 30);
    assert.equal(row(report, "client.patch.update1000.current").status, "improved");
    assert.deepEqual(report.regressions.map((r) => r.id), ["client.patch.reorder1000.current"]);
  });

  it("treats a drop of a higher-is-better metric as a regression", () => {
    const report = compareResults(fixture("base"), fixture("throughput_drop"));
    assert.equal(report.ok, false);
    const r = row(report, "server.events_per_s.n1");
    assert.equal(r.status, "regression");
    assert.equal(r.change, 25);
  });

  it("honours a configurable threshold", () => {
    assert.equal(compareResults(fixture("base"), fixture("regressed"), { threshold: 40 }).ok, true);
    assert.equal(compareResults(fixture("base"), fixture("within"), { threshold: 5 }).ok, false);
  });

  it("warns instead of failing when the candidate was too noisy to trust", () => {
    const report = compareResults(fixture("base"), fixture("noisy"));
    assert.equal(report.ok, true);
    assert.equal(row(report, "client.patch.reorder1000.current").status, "noisy");
    assert.match(report.warnings.join("\n"), /noisy/);
  });

  it("fails on a noisy regression when asked to", () => {
    assert.equal(compareResults(fixture("base"), fixture("noisy"), { failOnNoisy: true }).ok, false);
  });

  it("lists metrics that exist on one side only, and fails on them only when strict", () => {
    const report = compareResults(fixture("base"), fixture("missing"));
    assert.equal(report.ok, true);
    assert.deepEqual(report.missing.sort(), ["client.patch.bigtext.current", "client.patch.new_case.current"]);
    assert.equal(compareResults(fixture("base"), fixture("missing"), { strictMissing: true }).ok, false);
  });

  it("ignores a regression smaller than the absolute floor", () => {
    const report = compareResults(fixture("base"), fixture("regressed"), { minDelta: 5 });
    assert.equal(report.ok, true);
  });

  it("warns when the two runs were not measured on the same machine or the box was busy", () => {
    const report = compareResults(fixture("base"), fixture("other_machine"));
    const text = report.warnings.join("\n");
    assert.match(text, /cpu/i);
    assert.match(text, /load/i);
    assert.equal(report.ok, true, "a warning about the environment does not by itself fail");
  });

  it("formats a table that names the verdict", () => {
    const text = formatReport(compareResults(fixture("base"), fixture("regressed")));
    assert.match(text, /REGRESSION/);
    assert.match(text, /client\.patch\.reorder1000\.current/);
    assert.match(text, /\+30\.0%/);
  });

  it("exports the default threshold", () => {
    assert.equal(DEFAULTS.threshold, 15);
  });
});

describe("compare CLI", () => {
  it("exits 0 for a pass, 1 for a regression, 2 for bad usage", () => {
    assert.equal(cli(path("base"), path("within")).status, 0);
    const failed = cli(path("base"), path("regressed"));
    assert.equal(failed.status, 1);
    assert.match(failed.stdout, /REGRESSION/);
    assert.equal(cli(path("base")).status, 2);
    assert.equal(cli(path("base"), path("nope")).status, 2);
  });

  it("takes --threshold and --fail-on-noisy", () => {
    assert.equal(cli(path("base"), path("regressed"), "--threshold", "40").status, 0);
    assert.equal(cli(path("base"), path("noisy")).status, 0);
    assert.equal(cli(path("base"), path("noisy"), "--fail-on-noisy").status, 1);
  });
});

describe("metric floors", () => {
  it("ignores a relative regression below the metric's own absolute floor", () => {
    const base = fixture("base");
    const candidate = fixture("regressed");
    base.metrics[0].floor = 5; // 10 ms -> 13 ms is +30% but only 3 ms
    const report = compareResults(base, candidate);
    assert.equal(row(report, "client.patch.reorder1000.current").status, "ok");
  });
});

describe("noise must not hide large regressions", () => {
  it("fails a +300% regression even when the run was noisy (cv 0.25)", () => {
    const candidate = fixture("base");
    candidate.metrics[0] = { ...candidate.metrics[0], median: 40, cv: 0.25 };
    const report = compareResults(fixture("base"), candidate);
    assert.equal(row(report, "client.patch.reorder1000.current").status, "regression");
    assert.equal(report.ok, false);
  });

  it("still downgrades a change within 3 x cv", () => {
    const candidate = fixture("base");
    candidate.metrics[0] = { ...candidate.metrics[0], median: 12.5, cv: 0.25 }; // +25% < 75%
    assert.equal(row(compareResults(fixture("base"), candidate), "client.patch.reorder1000.current").status, "noisy");
  });
});

describe("invalid and incomparable input", () => {
  const withMetric = (change) => {
    const result = fixture("base");
    result.metrics[0] = { ...result.metrics[0], ...change };
    return result;
  };

  it("treats a NaN or missing median as an error, not as ok", () => {
    for (const median of [NaN, null, undefined, "7"]) {
      const report = compareResults(fixture("base"), withMetric({ median }));
      assert.equal(report.ok, false, `median ${median}`);
      assert.match(report.errors.join("\n"), /median/);
    }
  });

  it("reports a unit or direction mismatch as an error", () => {
    assert.match(compareResults(fixture("base"), withMetric({ unit: "s" })).errors.join("\n"), /unit/);
    assert.match(compareResults(fixture("base"), withMetric({ better: "higher" })).errors.join("\n"), /better/);
  });

  it("reports a schema mismatch as an error", () => {
    const candidate = fixture("base");
    candidate.schema = 2;
    assert.match(compareResults(fixture("base"), candidate).errors.join("\n"), /schema/);
  });

  it("refuses to compare short and full runs whose sample counts differ", () => {
    const candidate = fixture("base");
    candidate.mode = "full";
    candidate.metrics[0] = { ...candidate.metrics[0], n: 90 };
    const report = compareResults(fixture("base"), candidate);
    assert.equal(report.ok, false);
    assert.match(report.errors.join("\n"), /short.*full|mode/);
  });

  it("keeps a finite change when the base was zero (JSON must not turn it into null)", () => {
    const base = fixture("base");
    base.metrics[0] = { ...base.metrics[0], median: 0 };
    const report = compareResults(base, fixture("base"));
    const r = row(report, "client.patch.reorder1000.current");
    assert.equal(Number.isFinite(r.change), true);
    assert.equal(JSON.parse(JSON.stringify(r)).change, r.change);
    assert.equal(r.status, "regression");
  });

  it("starts the report with a loud notice when the machines differ", () => {
    const text = formatReport(compareResults(fixture("base"), fixture("other_machine")));
    assert.match(text.split("\n")[0], /NOT COMPARABLE|WARNING/);
  });

  it("exits 2 for an invalid or incomparable file", () => {
    const dir = fileURLToPath(new URL("./fixtures/", import.meta.url));
    const bad = fixture("base");
    bad.metrics[0].median = null;
    const file = `${process.env.TMPDIR || "/tmp"}/bad-${process.pid}.json`;
    writeFileSync(file, JSON.stringify(bad));
    try {
      assert.equal(cli(path("base"), file).status, 2);
    } finally {
      rmSync(file, { force: true });
    }
    void dir;
  });
});

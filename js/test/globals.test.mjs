// The hand written typings of window.AzuSpark must name every member of the real object.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { loadSpark } from "./helpers.mjs";

describe("azu-spark-global.d.ts", () => {
  it("declares every member of window.AzuSpark, and the telemetry events", async () => {
    await loadSpark();
    const typings = readFileSync(new URL("../azu-spark-global.d.ts", import.meta.url), "utf8");
    const interfaceBody = typings.slice(typings.indexOf("export interface AzuSpark"));
    for (const member of Object.keys(window.AzuSpark)) {
      assert.ok(new RegExp(`(readonly )?${member}\\b`).test(interfaceBody), `${member} is not declared`);
    }
    for (const name of ["state", "rtt", "timing", "delivery", "reconnect"]) assert.ok(typings.includes(name) || readFileSync(new URL("../azu-spark.d.ts", import.meta.url), "utf8").includes(name));
  });
});

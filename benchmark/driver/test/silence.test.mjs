import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { check } from "../conformance.mjs";
import { cases, missing } from "../contract.mjs";
import { skippedApps } from "../run.mjs";

// A fake app that answers the contract, optionally with a broken route table or a log line on 404.
function fakeApp({ breakPath = null, logOn404 = false, logOnOk = false } = {}) {
  const answers = new Map(cases().map(([, p, status, type, body]) => [p, [status, type, body]]));
  let logged = "";
  const server = http.createServer((req, res) => {
    const hit = answers.get(req.url);
    if (!hit) { if (logOn404) logged += "ERROR no route\n"; res.writeHead(404, { "content-type": "text/plain", "content-length": 9 }); return res.end("Not Found"); }
    if (logOnOk) logged += "INFO request\n";
    let [status, type, body] = hit;
    if (req.url === breakPath) body = body + "x";
    res.writeHead(status, { "content-type": type, "content-length": Buffer.byteLength(body) });
    res.end(body);
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({ base: `http://127.0.0.1:${server.address().port}`, output: () => logged, close: () => server.close() })));
}

test("a conformant app passes", async () => {
  const app = await fakeApp();
  const r = await check(app.base, { output: app.output });
  app.close();
  assert.deepEqual(r.failures, []);
  assert.equal(r.notFoundLogging.logs, false);
});

test("a deliberately wrong route table is a failure that names the route", async () => {
  const app = await fakeApp({ breakPath: "/api/v1/resource57/42" });
  const r = await check(app.base, { output: app.output });
  app.close();
  assert.ok(r.failures.some((f) => f.path === "/api/v1/resource57/42" && /body differs/.test(f.what)));
});

test("logging on a measured route fails, logging on a 404 is only reported", async () => {
  const noisy = await fakeApp({ logOnOk: true });
  const bad = await check(noisy.base, { output: noisy.output });
  noisy.close();
  assert.ok(bad.failures.some((f) => f.scenario === "logging"));

  const on404 = await fakeApp({ logOn404: true });
  const ok = await check(on404.base, { output: on404.output });
  on404.close();
  assert.deepEqual(ok.failures, []);
  assert.equal(ok.notFoundLogging.logs, true);
  assert.ok(ok.notFoundLogging.bytes > 0);
  assert.equal(missing.length >= 1, true);
});

test("skippedApps lists every requested app that is not measured", () => {
  const apps = [{ name: "a", status: "ok" }, { name: "b", status: "skipped: not conformant (2 difference(s))" }, { name: "c", status: "skipped: not built (x)" }];
  assert.deepEqual(skippedApps(apps).map((a) => a.name), ["b", "c"]);
});

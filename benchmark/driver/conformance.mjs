#!/usr/bin/env node
// Requests every scenario from a running app and diffs status, media type and body against the contract.
//   node conformance.mjs --url http://127.0.0.1:3000 [--ws] [--json]
// Exit 0 when everything matches. Headers other than content-type are reported, not compared.
import { cases, missing } from "./contract.mjs";

export async function check(base, { ws = false } = {}) {
  const failures = [];
  const extra = new Set();
  const fail = (scenario, path, what) => failures.push({ scenario, path, what });
  for (const [scenario, path, status, type, body] of cases()) {
    let res, text;
    try { res = await fetch(base + path); text = await res.text(); } catch (e) { fail(scenario, path, `request failed: ${e.message}`); continue; }
    if (res.status !== status) fail(scenario, path, `status ${res.status}, want ${status}`);
    const got = (res.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
    if (got !== type) fail(scenario, path, `content-type ${JSON.stringify(got)}, want ${JSON.stringify(type)}`);
    if (text !== body) fail(scenario, path, `body differs: got ${JSON.stringify(text.slice(0, 160))}, want ${JSON.stringify(body.slice(0, 160))}`);
    for (const name of res.headers.keys()) extra.add(name);
  }
  for (const [scenario, path, status] of missing) {
    try { const res = await fetch(base + path); await res.text(); if (res.status !== status) fail(scenario, path, `status ${res.status}, want ${status}`); }
    catch (e) { fail(scenario, path, `request failed: ${e.message}`); }
  }
  if (ws) failures.push(...(await checkWebSocket(base)));
  return { failures, headers: [...extra].sort() };
}

// Three clients; every message one sends must reach all three, sender included, unchanged.
async function checkWebSocket(base) {
  const failures = [];
  const url = base.replace(/^http/, "ws") + "/ws";
  const clients = [];
  const inbox = [[], [], []];
  try {
    for (let i = 0; i < 3; i++) {
      const sock = new WebSocket(url);
      await new Promise((resolve, reject) => { sock.onopen = resolve; sock.onerror = () => reject(new Error("connect failed")); setTimeout(() => reject(new Error("connect timeout")), 5000); });
      sock.onmessage = (e) => inbox[i].push(String(e.data));
      clients.push(sock);
    }
    await new Promise((r) => setTimeout(r, 200)); // let every connection subscribe
    clients[0].send("ping-from-0");
    clients[2].send("ping-from-2");
    await new Promise((r) => setTimeout(r, 500));
    for (let i = 0; i < 3; i++) {
      const got = [...inbox[i]].sort().join("|");
      if (got !== "ping-from-0|ping-from-2") failures.push({ scenario: "websocket", path: "/ws", what: `client ${i} received ${JSON.stringify(inbox[i])}` });
    }
  } catch (e) {
    failures.push({ scenario: "websocket", path: "/ws", what: e.message });
  } finally {
    for (const c of clients) try { c.close(); } catch {}
  }
  return failures;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
  const base = opt("--url", "http://127.0.0.1:3000");
  const { failures, headers } = await check(base, { ws: args.includes("--ws") });
  if (args.includes("--json")) console.log(JSON.stringify({ failures, headers }));
  else {
    console.log(`response headers seen: ${headers.join(", ")}`);
    for (const f of failures) console.log(`FAIL ${f.scenario} ${f.path}: ${f.what}`);
    console.log(failures.length ? `${failures.length} failure(s)` : "conformant");
  }
  process.exit(failures.length ? 1 : 0);
}

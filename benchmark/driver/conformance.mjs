#!/usr/bin/env node
// Requests every scenario from a running app and diffs status, media type and body against the contract.
//   node conformance.mjs --url http://127.0.0.1:3000 [--ws] [--json]
// Exit 0 when everything matches. Headers other than content-type and the framing ones are reported, not compared.
import net from "node:net";
import { cases, missing } from "./contract.mjs";

// One GET over a raw socket with exactly the bytes wrk sends (request line and Host only), so the answer is the one the
// load generator gets: no Accept, no Accept-Encoding, no User-Agent. Keep-alive is HTTP/1.1's default, as in wrk.
export function rawGet(port, path, timeoutMs = 5000) {
  return rawGetMany(port, [path], timeoutMs).then((r) => r[0]);
}

// Several requests, one after the other, on ONE keep-alive socket (the way wrk reuses connections).
export function rawGetMany(port, paths, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(port, "127.0.0.1");
    let buf = Buffer.alloc(0);
    let closed = false;
    const results = [];
    const timer = setTimeout(() => { sock.destroy(); reject(new Error("timeout")); }, timeoutMs);
    const fin = (err) => { clearTimeout(timer); sock.destroy(); err ? reject(err) : resolve(results); };
    const send = () => sock.write(`GET ${paths[results.length]} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`);
    const pump = () => {
      for (;;) {
        const r = parseResponse(buf, closed);
        if (!r) return closed ? fin(new Error("connection closed before a full response")) : undefined;
        if (r.malformed) return fin(new Error(`malformed response: ${r.malformed}`));
        results.push(r);
        buf = buf.subarray(r.bytes);
        if (results.length === paths.length) return fin();
        send();
      }
    };
    sock.on("error", (e) => fin(e));
    sock.on("connect", send);
    sock.on("close", () => { closed = true; pump(); });
    sock.on("data", (d) => { buf = Buffer.concat([buf, d]); pump(); });
  });
}

// Returns null while the response is incomplete. `bytes` counts the whole response on the wire.
export function parseResponse(buf, closed) {
  const end = buf.indexOf("\r\n\r\n");
  if (end < 0) return null;
  const lines = buf.subarray(0, end).toString("latin1").split("\r\n");
  const status = parseInt(/^HTTP\/1\.[01] (\d{3})/.exec(lines[0])?.[1] || "0", 10);
  const headers = {};
  let duplicateContentLength = false;
  let obsFold = false;
  for (const l of lines.slice(1)) {
    if (/^[ \t]/.test(l)) { obsFold = true; continue; } // a folded header line (obsolete, and ambiguous to parsers)
    const i = l.indexOf(":");
    if (i <= 0) continue;
    const name = l.slice(0, i).trim().toLowerCase();
    if (name === "content-length" && name in headers) duplicateContentLength = true;
    headers[name] = l.slice(i + 1).trim();
  }
  const flags = { duplicateContentLength, obsFold };
  const start = end + 4;
  let body, total;
  if ((headers["transfer-encoding"] || "").toLowerCase().includes("chunked")) {
    let pos = start; const parts = [];
    for (;;) {
      const eol = buf.indexOf("\r\n", pos);
      if (eol < 0) return null;
      const raw = buf.subarray(pos, eol).toString("latin1").split(";")[0].trim();
      const size = /^[0-9a-fA-F]+$/.test(raw) ? parseInt(raw, 16) : NaN;
      if (!Number.isFinite(size) || size < 0) return { malformed: `bad chunk size ${JSON.stringify(raw.slice(0, 20))}`, bytes: buf.length };
      if (size === 0) { if (buf.length < eol + 4) return null; total = eol + 4; break; }
      if (buf.length < eol + 2 + size + 2) return null;
      parts.push(buf.subarray(eol + 2, eol + 2 + size)); pos = eol + 2 + size + 2;
    }
    body = Buffer.concat(parts);
  } else if (headers["content-length"] !== undefined) {
    const n = parseInt(headers["content-length"], 10);
    if (!/^\d+$/.test(headers["content-length"])) return { malformed: `bad Content-Length ${JSON.stringify(headers["content-length"].slice(0, 20))}`, bytes: buf.length };
    if (buf.length < start + n) return null;
    body = buf.subarray(start, start + n); total = start + n;
  } else { if (!closed) return null; body = buf.subarray(start); total = buf.length; }
  return { status, headers, body: body.toString("utf8"), bytes: total, chunked: "transfer-encoding" in headers, ...flags };
}

// Requests every scenario the way wrk does and diffs status, media type and body against the contract; also asserts
// framing (Content-Length, not chunked), no Content-Encoding, keep-alive. Returns what differs plus, for the report,
// the extra header names, the content types with their parameters and the response bytes of each scenario.
export async function check(base, { ws = false, output = null } = {}) {
  const port = new URL(base).port;
  const failures = [];
  const extra = new Set();
  const contentTypes = {};
  const bytes = {};
  const fail = (scenario, path, what) => failures.push({ scenario, path, what });
  for (const [scenario, path, status, type, body] of cases()) {
    let res;
    try { res = await rawGet(port, path); } catch (e) { fail(scenario, path, `request failed: ${e.message}`); continue; }
    if (res.status !== status) fail(scenario, path, `status ${res.status}, want ${status}`);
    const ct = res.headers["content-type"] || "";
    if (ct.split(";")[0].trim().toLowerCase() !== type) fail(scenario, path, `content-type ${JSON.stringify(ct)}, want ${JSON.stringify(type)}`);
    if (res.body !== body) fail(scenario, path, `body differs: got ${JSON.stringify(res.body.slice(0, 160))}, want ${JSON.stringify(body.slice(0, 160))}`);
    if (res.duplicateContentLength) fail(scenario, path, "duplicate Content-Length header");
    if (res.obsFold) fail(scenario, path, "folded (obs-fold) header line");
    if (res.chunked) fail(scenario, path, "response is chunked (want Content-Length)");
    else if (res.headers["content-length"] === undefined) fail(scenario, path, "no Content-Length");
    if (res.headers["content-encoding"]) fail(scenario, path, `Content-Encoding ${res.headers["content-encoding"]} on a request without Accept-Encoding`);
    if ((res.headers["connection"] || "").toLowerCase() === "close") fail(scenario, path, "Connection: close on a keep-alive request");
    contentTypes[scenario] = ct;
    bytes[scenario] = res.bytes;
    for (const name of Object.keys(res.headers)) extra.add(name);
  }
  // keep-alive: two requests on one socket must both be answered (wrk reuses its connections)
  try {
    const [a, b] = await rawGetMany(port, ["/plaintext", "/plaintext"]);
    if (a.status !== 200 || b.status !== 200 || a.body !== b.body) fail("keepalive", "/plaintext", "two requests on one socket were not both answered identically");
  } catch (e) { fail("keepalive", "/plaintext", `two requests on one socket: ${e.message}`); }
  for (const [scenario, path, status] of missing) {
    try { const res = await rawGet(port, path); if (res.status !== status) fail(scenario, path, `status ${res.status}, want ${status}`); }
    catch (e) { fail(scenario, path, `request failed: ${e.message}`); }
  }
  if (ws) failures.push(...(await checkWebSocket(base)));
  // after ALL of it (200s, 404s, WebSocket) the app must not have written to stdout or stderr: logging would be part
  // of the cost
  if (output) {
    await new Promise((r) => setTimeout(r, 200));
    const grown = output();
    if (grown) fail("logging", "-", `the app wrote to stdout/stderr while serving: ${JSON.stringify(grown.slice(0, 120))}`);
  }
  return { failures, headers: [...extra].sort(), contentTypes, bytes };
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
  const { failures, headers, contentTypes, bytes } = await check(base, { ws: args.includes("--ws") });
  if (args.includes("--json")) console.log(JSON.stringify({ failures, headers, contentTypes, bytes }));
  else {
    console.log(`response headers seen: ${headers.join(", ")}`);
    console.log(`content types: ${JSON.stringify(contentTypes)}; response bytes: ${JSON.stringify(bytes)}`);
    for (const f of failures) console.log(`FAIL ${f.scenario} ${f.path}: ${f.what}`);
    console.log(failures.length ? `${failures.length} failure(s)` : "conformant");
  }
  process.exit(failures.length ? 1 : 0);
}

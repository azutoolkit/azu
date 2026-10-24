// Compressed frames: the client announces gzip, inflates binary frames with DecompressionStream, and applies
// every frame in the order it arrived, whatever its kind. The server's side is spec/azu/spark/compression_spec.cr.
import assert from "node:assert/strict";
import { gzipSync } from "node:zlib";
import { afterEach, beforeEach, describe, it } from "node:test";
import { FakeSocket, connected, loadSpark, tick, until } from "./helpers.mjs";

const LIMIT = 1_048_576;
const ROOT = '<div data-spark-root data-spark-id="r" data-spark-token="t"><i id="mark"></i></div>';

let spark;
let heard;
let errors;
const note = (detail) => heard.push(detail.n);
const oops = (detail) => errors.push(detail);
const diff = (n, extra = {}) => ({ v: 1, type: "diff", seq: n, patches: [], snapshots: {}, events: [{ target: "r", name: "mark", payload: { n } }], ...extra });
const binary = (frame) => gzipSync(Buffer.from(JSON.stringify(frame)));
const text = (socket, frame) => socket.receive(frame);

beforeEach(async () => {
  spark = await loadSpark();
  document.body.innerHTML = ROOT;
  spark.allowCompression();
  heard = [];
  errors = [];
  window.AzuSpark.on("mark", note);
  window.AzuSpark.on("error", oops);
  await tick();
});

afterEach(async () => {
  window.AzuSpark.disconnect();
  await tick(5);
  window.AzuSpark.off("mark", note);
  window.AzuSpark.off("error", oops);
  FakeSocket.all.length = 0;
});

describe("announcing gzip", () => {
  it("lists gzip in the join when the browser can inflate it, and asks for arraybuffers", async () => {
    const socket = await connected();
    assert.deepEqual(socket.of("join")[0].enc, ["gzip"]);
    assert.equal(socket.binaryType, "arraybuffer");
  });

  it("announces nothing when DecompressionStream is missing", async () => {
    const saved = globalThis.DecompressionStream;
    delete globalThis.DecompressionStream;
    try {
      const socket = await connected();
      assert.equal("enc" in socket.of("join")[0], false);
    } finally {
      globalThis.DecompressionStream = saved;
    }
  });
});

describe("binary frames", () => {
  it("applies a gzip diff exactly as the same JSON sent as text", async () => {
    const socket = await connected();
    socket.receiveBinary(binary(diff(1)));
    await until(() => heard.length === 1, "the pushed event");
    text(socket, diff(2));
    await until(() => heard.length === 2, "the text diff");
    assert.deepEqual(heard, [1, 2]);
  });

  it("keeps arrival order when binary and text frames interleave", async () => {
    const socket = await connected();
    const big = (n) => binary(diff(n, { patches: [{ id: "r", html: "<b>" + "x".repeat(200000) + "</b>" }] }));
    socket.receiveBinary(big(1)); // inflating takes a while: the text frames behind it must wait
    text(socket, diff(2));
    text(socket, diff(3));
    socket.receiveBinary(binary(diff(4)));
    text(socket, diff(5));
    await until(() => heard.length === 5, "all five frames");
    assert.deepEqual(heard, [1, 2, 3, 4, 5]);
  });

  it("handles a text frame at once when no binary frame is waiting", async () => {
    const socket = await connected();
    socket.receiveBinary(binary(diff(1)));
    await until(() => heard.length === 1, "the binary frame");
    const before = window.AzuSpark.stats().bytes.in;
    text(socket, { type: "heartbeat", id: 999 });
    assert.ok(window.AzuSpark.stats().bytes.in > before, "counted before the call returned");
  });

  it("counts the bytes that crossed the wire for a binary frame, not the inflated size", async () => {
    const socket = await connected();
    const frame = binary(diff(1, { patches: [{ id: "r", html: "<b>" + "x".repeat(50000) + "</b>" }] }));
    const before = window.AzuSpark.stats().bytes.in;
    socket.receiveBinary(frame);
    await until(() => heard.length === 1, "the frame");
    assert.equal(window.AzuSpark.stats().bytes.in - before, frame.length);
  });

  it("holds a text reply behind the binary diff that preceded it (the ack follows the patches)", async () => {
    const socket = await connected();
    document.body.querySelector("#mark").setAttribute("spark-click", "go");
    const seen = [];
    window.AzuSpark.on("delivery", (detail) => seen.push(detail.phase));
    document.getElementById("mark").dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
    const sent = socket.events[0];
    socket.receiveBinary(binary(diff(1, { ack: sent.eid })));
    text(socket, { type: "reply", id: sent.id, target: "r", ack: sent.eid });
    await until(() => heard.length === 1 && seen.includes("acked"), "the diff and the ack");
    assert.deepEqual(heard, [1]);
    assert.equal(socket.events.length, 1, "the event was not resent");
  });

  it("survives a long run of frames without holding on to any", async () => {
    const socket = await connected();
    for (let n = 1; n <= 200; n++) socket.receiveBinary(binary(diff(n)));
    await until(() => heard.length === 200, "200 frames", 10000);
    assert.deepEqual(heard, Array.from({ length: 200 }, (_, i) => i + 1));
    const before = window.AzuSpark.stats().bytes.in;
    text(socket, diff(201));
    assert.ok(window.AzuSpark.stats().bytes.in > before, "back to handling text frames synchronously");
    await until(() => heard.length === 201, "the last frame");
  });
});

describe("failures", () => {
  it("refuses a frame that inflates past the limit while it streams, and reports patch_failed", async () => {
    const socket = await connected();
    const bomb = gzipSync(Buffer.alloc(LIMIT * 64, 0x20)); // 64 MiB of spaces: about 65 KB compressed
    assert.ok(bomb.length < 100_000);
    socket.receiveBinary(bomb);
    await until(() => errors.length > 0, "the error");
    assert.equal(errors[0].code, "patch_failed");
    assert.match(errors[0].message, /1048576/);
    assert.deepEqual(heard, []);
  });

  it("accepts a frame right at the limit", async () => {
    const socket = await connected();
    const json = JSON.stringify(diff(1));
    socket.receiveBinary(gzipSync(Buffer.from(json + " ".repeat(LIMIT - json.length))));
    await until(() => heard.length === 1, "the frame");
    assert.deepEqual(errors, []);
  });

  it("reports garbage as patch_failed, reconnects, and stops announcing gzip", async () => {
    const socket = await connected();
    socket.receiveBinary(Buffer.from("not gzip at all"));
    await until(() => errors.length > 0, "the error");
    assert.equal(errors[0].code, "patch_failed");
    assert.equal(socket.readyState, FakeSocket.CLOSED, "the connection is reset so the page is rebuilt from its snapshot");
    const next = await until(() => FakeSocket.all.length > 1 && FakeSocket.all[FakeSocket.all.length - 1], "a new socket", 10000).then(() => FakeSocket.all[FakeSocket.all.length - 1]);
    next.receive({ type: "hello", heartbeat: 20000, max_size: 65536 });
    assert.equal("enc" in next.of("join")[0], false, "after a failure the client asks for plain frames");
  });

  it("drops the frames that were waiting behind a failed one together with it", async () => {
    const socket = await connected();
    socket.receiveBinary(Buffer.from("junk"));
    text(socket, diff(1)); // behind the junk: applying it alone would skip a diff
    await until(() => errors.length > 0, "the error");
    await tick(20);
    assert.deepEqual(heard, []);
  });

  it("ignores a binary frame that arrives on a socket that is no longer current", async () => {
    const socket = await connected();
    socket.receiveBinary(binary(diff(1)));
    socket.drop();
    await tick(20);
    assert.ok(heard.length <= 1);
    assert.deepEqual(errors, []);
  });
});

describe("a frame that never finishes", () => {
  it("is given up after the inflate timeout: patch_failed, reset, plain rejoin, and later frames are not stuck", async () => {
    const saved = globalThis.DecompressionStream;
    const savedTimeout = spark.config.inflateTimeout;
    globalThis.DecompressionStream = class { // never produces anything, never ends
      constructor() {
        this.readable = new ReadableStream({ pull: () => new Promise(() => {}) });
        this.writable = new WritableStream();
      }
    };
    spark.config.inflateTimeout = 40;
    try {
      const socket = await connected();
      socket.receiveBinary(binary(diff(1)));
      text(socket, diff(2)); // queued behind the hung frame
      await until(() => errors.length > 0, "the timeout", 2000);
      assert.equal(errors[0].code, "patch_failed");
      assert.match(errors[0].message, /too long/);
      assert.equal(socket.readyState, FakeSocket.CLOSED);
      await until(() => FakeSocket.all.length > 1, "a new socket", 10000);
      const next = FakeSocket.all[FakeSocket.all.length - 1];
      next.receive({ type: "hello", heartbeat: 20000, max_size: 65536 });
      assert.equal("enc" in next.of("join")[0], false);
      assert.deepEqual(heard, []);
    } finally {
      globalThis.DecompressionStream = saved;
      spark.config.inflateTimeout = savedTimeout;
    }
  });
});

describe("the compressed size", () => {
  it("is capped before anything is inflated", async () => {
    const saved = globalThis.DecompressionStream;
    let built = 0;
    globalThis.DecompressionStream = class extends saved { constructor(...args) { super(...args); built++; } };
    try {
      const socket = await connected();
      socket.receiveBinary(Buffer.alloc(524289, 7));
      await until(() => errors.length > 0, "the error");
      assert.equal(errors[0].code, "patch_failed");
      assert.match(errors[0].message, /524288/);
      assert.equal(built, 0, "nothing was inflated");
    } finally {
      globalThis.DecompressionStream = saved;
    }
  });

  it("accepts a frame right at the cap", async () => {
    const socket = await connected();
    const json = JSON.stringify(diff(1));
    const body = gzipSync(Buffer.from(json));
    assert.ok(body.length < 524288);
    socket.receiveBinary(body);
    await until(() => heard.length === 1, "the frame");
    assert.deepEqual(errors, []);
  });
});

describe("a path that closes on binary frames", () => {
  const nextJoin = async () => {
    await until(() => FakeSocket.all.length > 1, "a new socket", 10000);
    const next = FakeSocket.all[FakeSocket.all.length - 1];
    next.receive({ type: "hello", heartbeat: 20000, max_size: 65536 });
    return next.of("join")[0];
  };

  it("stops announcing gzip when the connection ends right after the first binary frame", async () => {
    const socket = await connected();
    socket.receiveBinary(binary(diff(1)));
    socket.drop(); // the middlebox kills the socket at the binary frame
    assert.equal("enc" in (await nextJoin()), false);
  });

  it("keeps announcing it when the connection had applied a text frame since", async () => {
    const socket = await connected();
    socket.receiveBinary(binary(diff(1)));
    await until(() => heard.length === 1, "the binary frame");
    text(socket, diff(2));
    socket.drop();
    assert.deepEqual((await nextJoin()).enc, ["gzip"]);
  });

  it("does not blame the binary frame for a close we asked for", async () => {
    const socket = await connected();
    socket.receiveBinary(binary(diff(1)));
    await until(() => heard.length === 1, "the binary frame");
    socket.onclose({ code: 1000, reason: "hidden idle" });
    assert.deepEqual((await nextJoin()).enc, ["gzip"]);
  });
});

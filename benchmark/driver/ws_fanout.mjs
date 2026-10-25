// WebSocket fan-out driver. N clients connect to /ws; S senders each run broadcast rounds in a closed loop:
// send one message, wait until all N clients have received it (the server broadcasts every message to every
// client, the sender included), then send the next. Needs node >= 22 (global WebSocket).
//
// One run = `duration` seconds of rounds after the clients are connected. Reported:
//   deliveries_per_s  messages received by clients per second (rounds x N): the throughput figure
//   p50_ms / p99_ms   latency from send to receive, per delivery
//   round_p50_ms / round_p99_ms   send until the LAST client got it
// The driver is one node process: at high rates it can be the bottleneck, so compare apps on one machine
// and look at `driver_cpu_pct` (a value near 100 means the driver, not the server, limited the run).
import { percentile } from "./stats.mjs";

export async function connect(url, n) {
  const clients = [];
  for (let i = 0; i < n; i++) {
    const sock = new WebSocket(url);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`websocket connect timeout (client ${i})`)), 10000);
      sock.onopen = () => { clearTimeout(timer); resolve(); };
      sock.onerror = () => { clearTimeout(timer); reject(new Error(`websocket connect failed (client ${i})`)); };
    });
    clients.push(sock);
  }
  return clients;
}

export async function runFanout({ url, clients: n = 50, senders = 4, duration = 10 }) {
  const socks = await connect(url, n);
  await new Promise((r) => setTimeout(r, 300)); // every connection subscribed
  const cpuStart = process.cpuUsage();
  const wallStart = performance.now();
  const rounds = new Map(); // id -> { sentAt, received }
  const deliveryMs = [];
  const roundMs = [];
  let stopAt = wallStart + duration * 1000;
  let completed = 0;
  let errors = 0;
  const senderLoops = [];

  const sendRound = (sock, tag, seq) => {
    const id = `${tag}:${seq}`;
    rounds.set(id, { sentAt: performance.now(), received: 0, sender: sock, tag, seq });
    sock.send(id);
  };

  for (const sock of socks) {
    sock.onmessage = (e) => {
      const id = String(e.data);
      const r = rounds.get(id);
      if (!r) { errors++; return; }
      const now = performance.now();
      deliveryMs.push(now - r.sentAt);
      if (++r.received === n) {
        rounds.delete(id);
        roundMs.push(now - r.sentAt);
        completed++;
        if (now < stopAt) sendRound(r.sender, r.tag, r.seq + 1);
      }
    };
  }
  for (let s = 0; s < Math.min(senders, n); s++) senderLoops.push(socks[s]);
  senderLoops.forEach((sock, s) => sendRound(sock, `s${s}`, 0));

  while (performance.now() < stopAt) await new Promise((r) => setTimeout(r, 50));
  const drainUntil = performance.now() + 3000;
  while (rounds.size && performance.now() < drainUntil) await new Promise((r) => setTimeout(r, 20));
  const elapsed = (performance.now() - wallStart) / 1000;
  const cpu = process.cpuUsage(cpuStart);
  const lost = rounds.size;
  for (const s of socks) try { s.close(); } catch {}
  await new Promise((r) => setTimeout(r, 200));
  return {
    rps: deliveryMs.length / elapsed,
    rounds_per_s: completed / elapsed,
    p50_ms: percentile(deliveryMs, 50),
    p90_ms: percentile(deliveryMs, 90),
    p99_ms: percentile(deliveryMs, 99),
    round_p50_ms: percentile(roundMs, 50),
    round_p99_ms: percentile(roundMs, 99),
    requests: deliveryMs.length,
    non2xx: 0,
    socket_errors: errors + lost,
    driver_cpu_pct: ((cpu.user + cpu.system) / 1000 / (elapsed * 1000)) * 100,
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const a = process.argv.slice(2);
  const opt = (k, d) => { const i = a.indexOf(k); return i >= 0 ? a[i + 1] : d; };
  const out = await runFanout({
    url: opt("--url", "ws://127.0.0.1:3000/ws"),
    clients: parseInt(opt("--clients", "50"), 10),
    senders: parseInt(opt("--senders", "4"), 10),
    duration: parseFloat(opt("--duration", "10")),
  });
  console.log(JSON.stringify(out));
  process.exit(0);
}

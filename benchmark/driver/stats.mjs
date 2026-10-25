// Summary statistics and the wrk output parser. No dependencies; tested by test/stats.test.mjs.
export function median(xs) {
  if (!xs.length) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

export function mean(xs) { return xs.reduce((a, b) => a + b, 0) / xs.length; }

// Sample standard deviation (n - 1); 0 for a single sample.
export function stddev(xs) {
  if (xs.length < 2) return 0;
  const m = mean(xs);
  return Math.sqrt(xs.reduce((a, x) => a + (x - m) ** 2, 0) / (xs.length - 1));
}

// Relative standard deviation in percent: how much the repetitions disagree with each other.
export function rsd(xs) {
  const m = mean(xs);
  return m === 0 ? 0 : (stddev(xs) / m) * 100;
}

export function summarize(xs) {
  return { n: xs.length, median: median(xs), min: Math.min(...xs), max: Math.max(...xs), mean: mean(xs), stddev: stddev(xs), rsd_pct: xs.length < 3 ? NaN : rsd(xs) }; // a spread of fewer than 3 samples says nothing
}

const UNIT = { us: 1e-3, ms: 1, s: 1000, m: 60000 };
export function toMs(text) {
  const m = /^([\d.]+)\s*(us|ms|s|m)$/.exec(text.trim());
  if (!m) throw new Error(`unparseable duration ${JSON.stringify(text)}`);
  return parseFloat(m[1]) * UNIT[m[2]];
}

// Parses the output of `wrk --latency`: requests per second, the latency percentiles (ms) and error counters.
export function parseWrk(out) {
  const rps = /Requests\/sec:\s+([\d.]+)/.exec(out);
  if (!rps) throw new Error("no Requests/sec in wrk output");
  const pct = (p) => {
    const m = new RegExp(`^\\s*${p}%\\s+([\\d.]+(?:us|ms|s|m))`, "m").exec(out);
    if (!m) throw new Error(`no ${p}% latency in wrk output`);
    return toMs(m[1]);
  };
  const non2xx = /Non-2xx or 3xx responses:\s+(\d+)/.exec(out);
  const sock = /Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)/.exec(out);
  const total = /(\d+) requests in/.exec(out);
  return {
    rps: parseFloat(rps[1]),
    p50_ms: pct(50), p90_ms: pct(90), p99_ms: pct(99),
    requests: total ? parseInt(total[1], 10) : 0,
    non2xx: non2xx ? parseInt(non2xx[1], 10) : 0,
    socket_errors: sock ? sock.slice(1).reduce((a, b) => a + parseInt(b, 10), 0) : 0,
  };
}

// Nearest-rank percentile of an unsorted array (p in 0..100).
export function percentile(xs, p) {
  if (!xs.length) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))];
}

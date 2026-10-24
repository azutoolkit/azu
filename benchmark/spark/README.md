# Spark benchmarks

A reproducible, additive benchmark suite for the Spark client and server. It changes nothing in
`src/` and is not part of `crystal spec`. The full explanation (what each number means, how to read
a comparison) is in [docs/reference/spark-benchmarks.md](../../docs/reference/spark-benchmarks.md).

```sh
scripts/bench_spark.sh                      # everything, short mode (a few minutes)
scripts/bench_spark.sh --suite client       # one suite: sizes, client or server
scripts/bench_spark.sh --mode full          # more repetitions, for a quiet machine
scripts/bench_spark.sh --compare base.json  # run, then diff against an earlier result
node --test "benchmark/spark/test/*.test.mjs"   # tests of the compare tool
```

## What is measured

| Suite | File | What |
|---|---|---|
| `sizes` | `sizes.mjs` | raw, gzip -9 and brotli bytes of the shipped client at every commit that changed it |
| `client` | `client.mjs` | patch engine, event pipeline, frame handling and heap in Chromium (Playwright) |
| `server` | `server_bench.cr`, `server.mjs` | events per second and latency through `Spark::Connection`, PubSub fan-out, memory per connection, and `Benchmark.ips` micro benchmarks of the delivery bookkeeping |

The client suite compares three arms on the same inputs, same machine, same session, interleaved
(repetition 1 runs naive, prev, current; repetition 2 runs prev, current, naive; and so on), 10
measured repetitions (15 in full mode) after one dropped warm-up repetition. Memory and micro metrics use
fewer cycles (3 to 6), so their `cv` is rough. Each repetition asserts the resulting page, that the Spark
arms kept focus, value and caret (the naive arm is the baseline that does not), and that the last event
frame carried the final input value:

- `naive`: no Spark client, `innerHTML` replacement (and one frame per input event for the pipeline case)
- `prev`: the client at the commit before slice 3 (`2c373cd`, override with `BENCH_PREV_COMMIT`), read from git
- `current`: `src/azu/spark/client/azu_spark.js` of this checkout, the script applications ship

No network is used: pages are served from memory, the socket is a fake the harness drives, and
`requestAnimationFrame` is a queue the harness pumps, so a patch is timed from "the frame arrived" to
"the new layout is computed". Painting and rasterising are not measured. The server suite runs the
server and the load generator as two processes of one release build.

Server numbers need four cautions. The `closed_loop_*` latencies come from a closed loop and are a lower
bound of the tail, most of all p99. Both processes use one thread, so at many connections the load
generator can be the bottleneck: compare arms (`eid_on` against `eid_off`), not ceilings. Sockets are set to
`TCP_NODELAY` (`serve --nodelay`) so the figures measure the server's work; Crystal's HTTP server leaves
Nagle's algorithm on by default, and the `nagle_on` metric runs the same round trip on such sockets. And
`used_kb_drift_per_cycle` is the rise of the heap in use (with every connection closed) per connect and
close cycle after the first one: a steady rise is a leak, a plateau is pooled memory.

## Requirements

- node 22 and `playwright` with chromium (`PLAYWRIGHT_MODULE`, `CHROMIUM_PATH`); without them the client suite is skipped
  (`BENCH_REQUIRED=1` makes a skip a failure)
- a Crystal compiler for the server suite (`BENCH_CRYSTAL`, default `crystal`; a docker wrapper works,
  then also set `BENCH_EXEC_PREFIX` to the same wrapper so the built binary runs where it was built)
- the full git history for `sizes` and for the `prev` arm (a shallow clone skips them with a warning)

## Result files

`scripts/bench_spark.sh` writes `benchmark/spark/results/spark-<UTC stamp>.json` (git-ignored), a
Markdown rendering next to it, and `-sizes.md` (the size table). A result is:

```json
{
  "schema": 1, "tool": "azu-spark-bench", "suite": "sizes+client+server", "mode": "short",
  "created": "2026-10-24T12:00:00.000Z",
  "env": { "cpu": "...", "cores": 4, "node": "v22.22.0", "chromium": "...", "crystal": "...",
           "load_before": [0.4, 0.3, 0.2], "load_after": [1.1, 0.8, 0.4], "git": "abc1234", "git_dirty": false },
  "metrics": [
    { "id": "client.patch.reorder1000.current", "unit": "ms", "better": "lower",
      "median": 64.6, "p95": 71.2, "cv": 0.04, "n": 30 }
  ]
}
```

- `median` and `p95` are over every sample of the metric; `n` is how many.
- `p95` is linearly interpolated. Client patch metrics pool every sample; server metrics have one sample per
  repetition (10 to 15), so their p95 is a rough figure.
- `cv` is the coefficient of variation (standard deviation over mean) of the per-repetition medians:
  the noise of that measurement on that run. A `cv` above 0.2 means the box was not steady.
- `better` says whether lower or higher is an improvement; `floor` (some metrics) is an absolute change
  below which a difference is noise (for example a few KB of heap).
- `extra` carries side information: the size history, whether focus survived a patch (`focus_kept`), lost deliveries.

## Comparing two runs

```sh
node benchmark/spark/compare.mjs base.json candidate.json [--threshold 15] [--noise-cv 0.2] [--fail-on-noisy] [--min-delta N] [--strict-missing] [--only PREFIX] [--json]
```

It compares medians, per metric, in the direction the metric prefers. Exit 0: no regression above the
threshold (default 15%). Exit 1: a regression. Exit 2: bad usage. A regression measured on a noisy
run (`cv` above `--noise-cv` on either side) is a warning, not a failure, unless `--fail-on-noisy`.
Exit 2 also covers invalid or incomparable files: a NaN or missing median, a schema, unit or `better`
mismatch, and short against full runs with different sample counts. A noisy run excuses only a change
below 3 x its `cv`; a larger one still fails. It also warns when the two files come from different CPUs, core counts, node or chromium versions or
modes, when a run started under load (load average above 70% of the cores) or on a dirty tree, and
lists metrics present on one side only.

Only compare results from the same machine, ideally measured back to back. Numbers from a shared cloud
container are relative: quote ratios and same-session comparisons, never absolute figures.

## Opt-in CI

`.github/workflows/spark-bench.yml` runs nightly and on `workflow_dispatch`, never on pull requests, and
is not a required check. Give `baseline_ref` and the same job measures that ref and this one on the same
runner and prints the comparison. The JSON files are uploaded as an artifact.

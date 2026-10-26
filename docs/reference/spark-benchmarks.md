# Spark benchmarks

The repository ships a benchmark suite for Spark in `benchmark/spark/`. It exists to answer relative
questions: did this change make patches slower, did the client grow, does delivery bookkeeping cost
throughput. It is not a source of absolute performance claims, and none are made here: the numbers
depend on the machine, and a shared CI runner or cloud container is noisy.

Nothing in the suite touches the framework. It is not part of `crystal spec`, and the required CI
checks do not run it.

## Running it

```sh
scripts/bench_spark.sh                      # sizes, client and server, short mode
scripts/bench_spark.sh --suite client       # one suite: sizes, client, server
scripts/bench_spark.sh --mode full          # more repetitions, for a quiet machine
scripts/bench_spark.sh --compare base.json  # run, then diff against an earlier result
```

The client suite needs node 22 with `playwright` and chromium (point `PLAYWRIGHT_MODULE` and
`CHROMIUM_PATH` at them); the server suite needs a Crystal compiler (`BENCH_CRYSTAL`). A suite whose tool is
missing is skipped with a message, or fails when `BENCH_REQUIRED=1`. The runner writes a JSON result file
(and a Markdown rendering) into `benchmark/spark/results/`.

## What is measured

**Sizes.** Raw, gzip -9 and brotli bytes of the shipped `azu_spark.js` at every commit that changed it, so
a regression is visible next to the change that caused it. These are exact numbers with no noise. A spec
(`spec/azu/spark/client_spec.cr`) enforces the gzip budget; the table shows how much room is left.

**Client patches.** A frame carrying a patch is handed to the client and the time until the new layout
is computed is measured, for a keyed list reordered (100, 1,000 and 5,000 rows), two rows swapped, one
row changed in a 1,000-row list, a long run of unkeyed children with one change, a 256 KB text node
edited, and a form with 500 inputs patched while one of them has focus and a caret. The form case also
records whether focus, value and caret survived (`focus_kept`). Painting is not measured, and neither is
the network: the page is served from memory and the socket is a fake.

**Client event pipeline.** 1,000 keystrokes into a field bound with `spark_change`, with and without the
server acknowledging as it goes: the script time, and how many frames reach the socket. Fewer frames for
the same final text is the point of coalescing.

**Client frame handling.** The cost of receiving one control frame through the connection code
(including the state machine's proof-of-life hook), next to a bare `JSON.parse` of the same text, and
the cost of one pure state-machine transition.

**Client memory.** The heap after garbage collection, after a warm-up and then after N and 2N patches
of the same list. The growth between the two is the number to watch: a leak shows as a steady slope,
while a one-off allocation does not.

**Server.** A release build of a small Spark server (`server_bench.cr`) and a load generator in a second
process:

- *events*: closed-loop `increment` events over WebSockets, with N components per connection, with and
  without event numbers (`eid`), which isolates the cost of the dedupe and acknowledgement bookkeeping;
  events per second and p50 and p99 round-trip latency. The load is closed loop (a client sends its next
  event after the previous reply), so a stall delays the sends that would have queued behind it: the
  `closed_loop_p99_ms` metrics are a lower bound of the tail an open-loop arrival would see. The `nagle_on`
  metrics run the same round trip with `WEBSOCKET_TCP_NODELAY=false`.
- *fanout*: a PubSub message delivered to M subscribed connections; the latency from publish to the diff
  arriving (paced, so messages do not queue) and the delivery rate under a burst. Lost deliveries are
  recorded.
- *memory*: GC-used heap and resident set per connection with N components, and what remains after the
  connections close.
- *micro*: `Benchmark.ips` for `Session#accept`, `Protocol.reply` and `diff` with and without `ack`, and
  `Inbound.from_json` with and without `eid`, as nanoseconds per operation.

## The comparison arms

Client numbers are compared against two baselines:

| arm | what it is |
|---|---|
| `naive` | no Spark client; the component's content is replaced with `innerHTML` |
| `prev` | the client at the commit before the keyed patch engine (`BENCH_PREV_COMMIT`), read from git |
| `current` | the shipped script of this checkout |

The arms run on the same pages, machine and session, interleaved: every repetition runs each arm once, in
a rotating order, so a slow patch of the machine hits all arms alike. The patch, keystroke and frame
metrics take 10 measured repetitions (15 in full mode) after one dropped warm-up repetition; the memory and
micro metrics take fewer (3 to 6 cycles or processes), so their `cv` is a rough guide only. Every repetition
checks that the page ended in the state the patch described, that Spark arms kept focus, value and caret,
and that the last event frame carried the final input value; a failed check fails the run.

## Reading a result

Each metric reports a median, a p95 and a coefficient of variation (`cv`) of the per-repetition medians.
Trust a difference only when it is larger than the `cv`. Compare ratios between arms of the same run, not
numbers between machines or between runs: on a shared machine two runs of identical code can differ by
tens of percent in a median, while the ratios between interleaved arms stay close. The environment block records the CPU, node, chromium and Crystal versions
and the load average before and after, so a result taken on a busy box can be recognised as one.

## Comparing two runs

```sh
node benchmark/spark/compare.mjs base.json candidate.json --threshold 15
```

The exit status is 0 when no metric got worse than the threshold (15% on medians by default), 1 on a
regression and 2 on bad usage. A regression measured on a noisy run is reported as a warning rather than a
failure, unless `--fail-on-noisy` is given; so are differences in CPU, core count or tool versions, a
run that started under load, and metrics that exist on one side only. Run the baseline and the candidate
on the same machine, back to back.

## In CI

`.github/workflows/spark-bench.yml` runs nightly and on demand. It is opt-in and not a required check.
With `baseline_ref` set, one job measures that ref and the current one on the same runner and prints the
comparison; the JSON files are uploaded as a workflow artifact.

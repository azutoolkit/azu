# Framework benchmarks

A reproducible suite that measures Azu next to other Crystal web frameworks on the same machine, with the
same responses, the same compiler and the same load. It exists so that any statement about Azu's speed has a
source: a command, a result file and a stated machine. **This page contains no numbers on purpose.** Numbers
belong to a result file (`benchmark/results/`, git-ignored) and to the machine that produced it. The suite
does not declare winners: it reports medians with their spread, and says when a run was too noisy to quote.

```sh
scripts/bench.sh                     # seed the database, build every app, check conformance, measure, write results
scripts/bench.sh env                 # print the environment only
scripts/bench.sh build               # build only
scripts/bench.sh conformance         # start every app and diff its answers against the contract
scripts/bench.sh run --apps azu,kemal --scenarios plaintext,json --runs 7 --duration 15
node --test benchmark/driver/test/   # tests of the statistics, the wrk parser and the contract
```

## What is measured

Every app serves the same routes and answers with byte-identical bodies and the same media types. The
expected answers are written down in `benchmark/driver/contract.mjs`, independently of the Crystal fixtures in
`benchmark/apps/common/bench.cr`, and `scripts/bench.sh conformance` (also run before every measurement)
diffs status, media type and body of every route. An app that deviates is excluded from the run, not
measured.

| Scenario | Request | What it exercises |
|---|---|---|
| `plaintext` | `GET /plaintext` -> `Hello, World!` (`text/plain`) | the floor: accept, parse, route, write |
| `json` | `GET /json` -> `{"message":"Hello, World!"}` | JSON serialization of a small value |
| `routing` | `GET /api/v1/resource<N>/<id>`, N cycling over 100 routes, ids over 997 values | a router with 100 parameterised routes, parameter extraction |
| `template` | `GET /template` -> an HTML page with a 20 item list, names HTML-escaped | the framework's template engine, escaping |
| `db_single` | `GET /db/item/<1..1000>` -> one row as JSON | one SQLite query per request through the framework's data access |
| `db_multi` | `GET /db/items` -> the first 20 rows as a JSON array | a 20 row query and array serialization |
| `websocket` | 50 clients on `/ws`; each message sent is broadcast to every client, the sender included | WebSocket fan-out (deliveries per second, latency send to receive) |

Unknown paths answer 404 (only the status is compared). The SQLite file is created by `benchmark/db/seed.sh`
(1000 rows) and opened by every app with the same pool size.

Per app the suite also records the startup time (process spawn until the first `200` on `/plaintext`), the
resident set size right after startup, and the RSS (`VmRSS`) and peak RSS (`VmHWM`) after each scenario. The
RSS columns are cumulative over the scenarios that ran before, because one process serves all of them.

## The apps

One program per framework in `benchmark/apps/<name>/src/app.cr`, built with `crystal build --release
--no-debug`, with versions pinned in `shard.yml` and `shard.lock` (the lock files are committed).

| App | Stack | Notes |
|---|---|---|
| `baseline` | `HTTP::Server`, a hand-written `case` on the path, ECR, crystal-sqlite3, `HTTP::WebSocketHandler` | the ceiling for this stack with no framework; its "router" is not a router |
| `azu` | `Azu::App`, default handler stack minus the request logger (`RequestId`, `Rescuer`, `SecurityHeaders`, `Static`), Crinja, CQL on SQLite, `Azu::Channel` | the only app whose DB scenarios go through an ORM |
| `kemal` 1.9.0 | default handlers, logging off, ECR, crystal-sqlite3, `ws` | |
| `athena` 0.23.0 | default listeners, annotation routing, ECR, crystal-sqlite3 | has no WebSocket support, so `websocket` is skipped |
| `lucky` 1.5.0 | `ErrorHandler`, `RouteHandler`, `RouteNotFoundHandler`, `HTMLPage`, crystal-sqlite3 | Avram is PostgreSQL-only, so raw SQLite; no WebSocket support |
| `azu-min` (opt-in) | `azu` with only `Handler::Rescuer` | separates router and endpoint cost from the default middleware |
| `azu-rawdb` (opt-in) | `azu` with crystal-sqlite3 instead of CQL | separates the ORM cost in the DB scenarios |

Add `--apps` to choose; the manifest is `benchmark/apps/manifest.json`. An app that cannot be built here is
skipped and said so in the result (`--require-all` turns that into a failure).

## Fairness rules

1. **Same compiler, same flags.** One Crystal version for every app, `--release --no-debug`, no
   `-Dpreview_mt`: every app runs the single threaded scheduler (the garbage collector may use its own
   threads). Multi-threaded runs are a different experiment and are not covered yet.
2. **Same bytes.** Bodies, status and media type are checked by the conformance script. Headers other than
   `Content-Type` are not compared (each framework adds its own: `Date`, `Content-Length`, `Referrer-Policy`,
   `X-Request-Id`, ...); the extra header names each app sends are printed by `conformance` so the
   differences are visible, not hidden.
3. **Each framework's default stack, request logging off.** No app adds middleware of its own, and none logs
   requests. Lucky logs every pipe at INFO even without its `LogHandler`; its log level is raised to `warn`.
   Whatever else the default stack does (Azu's security headers, Athena's listeners) is part of what a user
   of that framework pays and stays on. `azu-min` exists to show that cost.
4. **Idiomatic, not hand-tuned.** Each scenario is written the way that framework's documentation
   writes it. Where frameworks differ in ways that change the work done, that is a confound and is listed
   below instead of being engineered away.
5. **Same database access budget.** One SQLite file, pool of 4 connections (`BENCH_DB_POOL`) with the
   connections opened at boot for every app.
6. **Same sockets.** `TCP_NODELAY` decides whether a WebSocket frame waits about 40 ms for a delayed ACK. Azu
   sets it on upgraded sockets; the baseline and Kemal get it from a listener in `apps/common/bench.cr`.
   `BENCH_WS_NODELAY=0` turns it off for all apps (Azu then gets `WEBSOCKET_TCP_NODELAY=false`) to measure
   the socket defaults.
7. **One process per app, same machine, same session, interleaved.** The apps run side by side (idle ones
   cost nothing), and within every repetition each app is measured once, the order rotating, so slow drift of
   the machine hits every app alike.

### Known confounds (read before comparing)

- **Templates**: Azu renders a Crinja (Jinja) template looked up at request time; the baseline, Kemal and
  Athena render ECR, which the compiler turns into straight code; Lucky builds the page with its HTML DSL.
  The `template` scenario compares template *systems*, not routers.
- **Database**: Azu goes through CQL (query builder, model instances); the others call crystal-sqlite3
  directly. `azu-rawdb` removes the ORM from the picture.
- **JSON**: Azu, Kemal and the baseline call `to_json` and write the string; Athena and Lucky hand a value to
  their serializer. Bodies are identical, the work around them is not.
- **Routing**: the baseline dispatches by hand. Radix based routers (Azu, Kemal) and Lucky's router are
  compared in the `routing` scenario with 100 routes, which is a small table; deep trees and wildcards are not
  covered.
- **WebSocket**: Azu broadcasts through its `PubSub`; the baseline and Kemal loop over their socket list.
  Athena and Lucky are skipped.
- **Middleware that is not request logging**: see rule 3.

## How a run works

`scripts/bench.sh` (-> `benchmark/driver/run.mjs`):

1. Prints the environment (kernel, CPU, core count, memory, hypervisor flag, governor if exposed, load average,
   Crystal, wrk and node versions, git sha, the pinned shard versions of every app) and stores it in the result.
2. **Refuses to run when the machine is not quiet**: 1-minute load average above `--max-load` (0.5), CPU busier
   than `--max-busy` (10 %) over a 2 second sample, or another `crystal`, `shards`, `ameba`, compiler, linker,
   `wrk`-like process running. `--force` runs anyway and records the reasons in the result.
3. Starts every app (pinned, see below), measures its startup time, runs the conformance check and drops an app
   that fails it.
4. Per scenario: one unrecorded **warmup** run per app (default 3 s), then `--runs` (default 5) measured runs per
   app of `--duration` seconds (default 10), interleaved. HTTP scenarios use `wrk` (`-t2 -c64 --latency`,
   scenario scripts in `benchmark/driver/*.lua` cycle through routes and ids). The WebSocket scenario uses
   `benchmark/driver/ws_fanout.mjs`: N clients, S senders; a sender sends one message, waits until all N clients
   got it, then sends the next.
5. Writes `benchmark/results/bench-<UTC stamp>.json` and `.md` (git-ignored).

**CPU pinning.** With 4 or more CPUs and `taskset`, the apps run on the first half of the CPUs and the load
generators on the second half (`--server-cpus`, `--load-cpus`, or `BENCH_SERVER_CPUS` / `BENCH_LOAD_CPUS`). The
runner itself (which hosts the Node WebSocket driver) is pinned to the load generator CPUs too. On smaller machines nothing is pinned, and the result says so. On a laptop also fix the CPU governor and
disable turbo, or the first and the last run differ.

## Reproducing

Requirements: Crystal 1.19.1 (`BENCH_CRYSTAL` / `BENCH_SHARDS` name other commands), `wrk` (`apt install wrk`),
node 22 or newer, the `sqlite3` CLI and library, `libmagic-dev` (Athena's mime component), `libevent`, `openssl`,
`libyaml`, `gmp`, and network access to GitHub for `shards install`. Then:

```sh
scripts/bench.sh                # a full run takes about (apps x scenarios x (runs x duration + warmup)) seconds
scripts/bench.sh --apps azu,azu-min,azu-rawdb,baseline --scenarios plaintext,db_single --label azu-breakdown
```

`.github/workflows/bench.yml` runs the same thing on demand (`workflow_dispatch`) and uploads the result files.

## Reading results

- **Use the median** and look at **min and max** and the **rsd** (relative standard deviation, percent) next to
  it. If the rsd of a row is above 5 %, the repetitions disagree and that row is not a number to quote.
- **Relative columns** ("% of baseline") compare medians of the same session. Two apps within the combined
  spread of their runs are not different.
- **Latency is closed loop.** `wrk` keeps 64 connections busy, so the percentiles describe a saturated server
  with a standing queue, not the latency a user sees at a given request rate, and they under-report the tail
  (coordinated omission). Use them to compare apps with each other under identical pressure, not as service
  times. p99 is shown as the median over the runs and the worst run.
- **WebSocket**: `deliveries/s` is messages received by clients per second (rounds x clients). The Node driver
  is one thread; `driver_cpu_pct` in the JSON near 100 means the driver was the limit.
- **Errors**: non-2xx responses and socket errors are counted per row. Any non-zero value invalidates the row.
- **Memory** is RSS of the single process, cumulative across the scenarios before it, and includes the garbage
  collector's retained heap: it says how much the process holds, not how much a request needs.

### Noise

Shared cloud containers and CI runners are noisy: neighbours, CPU steal, frequency changes and a
virtualised clock all move results by more than the differences between frameworks. Therefore:

- numbers from a laptop or a shared container are good for **same-session before/after comparisons only**, for
  example to see whether a change to Azu's router moved `routing` between two commits measured back to back;
- **headline numbers (anything quoted outside a pull request) come only from a pinned, dedicated runner** with
  a recorded environment, at least 5 runs, rsd below 5 % and no `--force`;
- never mix results from different machines or different days in one table;
- a result file records `noisy` reasons when `--force` was used, and the Markdown output says what it is.

## Adding an app or a scenario

An app is a directory under `benchmark/apps/` with `shard.yml`, a committed `shard.lock` and `src/app.cr` that
requires `../../common/bench` and serves the routes of the contract on `HOST` and `PORT` (environment), using
`BENCH_DB` for the database. Add it to `manifest.json`. A scenario needs a contract entry in
`benchmark/driver/contract.mjs`, an entry in `manifest.json` (and a wrk Lua script if it must vary the request), and the
route in every app; `scripts/bench.sh conformance` tells you which app is missing it.

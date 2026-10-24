#!/usr/bin/env bash
# Azu framework benchmark suite: builds the benchmark apps, checks they answer identically, and measures them.
# Methodology, fairness rules and how to read results: docs/explanation/benchmarks.md
#
#   scripts/bench.sh [command] [options]
#
# Commands
#   env           print the environment (kernel, CPU, Crystal, wrk, node, shard versions) and exit
#   build         shards install + `crystal build --release --no-debug` for every selected app
#   conformance   start every built app, request every scenario, diff status/content-type/body against the contract
#   run           (default) seed the database, build, check conformance, measure, write JSON and Markdown results
#
# Options (all commands; the rest is passed to benchmark/driver/run.mjs)
#   --apps a,b        apps to use (default: baseline,azu,kemal,athena,lucky; also azu-min, azu-rawdb)
#   --scenarios a,b   plaintext,json,routing,template,db_single,db_multi,websocket (default: all)
#   --runs N          measured runs per app and scenario (default 5; fewer than 5 prints a warning)
#   --duration S      seconds per run (default 10)         --warmup S   seconds of the unrecorded warmup run (default 3)
#   --connections N   wrk connections (default 64)         --threads N  wrk threads (default 2)
#   --ws-clients N    websocket clients (default 50)       --ws-senders N   concurrent broadcasters (default 4)
#   --server-cpus L   taskset CPU list for the apps (default: first half of the CPUs, if there are 4 or more)
#   --load-cpus L     taskset CPU list for wrk (default: second half); env BENCH_SERVER_CPUS / BENCH_LOAD_CPUS
#   --out DIR         result directory (default benchmark/results, git-ignored)    --label TEXT  tag for the file name
#   --max-load X      refuse to run when the 1-minute load average is above X (default 0.5)
#   --max-busy PCT    refuse to run when the CPU was busier than PCT over 2 s (default 10)
#   --force           run although the machine is not quiet (the result records the reasons)
#   --require-all     fail when an app cannot be built, started or is not conformant (default: skip it and say so)
#   --no-build        run: use the binaries that exist
#   --reseed          recreate the SQLite database
#
# Environment: BENCH_CRYSTAL / BENCH_SHARDS name the compiler and shards commands (default crystal, shards).
# Needs: crystal 1.19.1+, wrk, node 22+, sqlite3 CLI, libmagic (Athena), and git access for `shards install`.
# The load generator and the apps share the machine: results are only comparable within one session.
set -euo pipefail
cd "$(dirname "$0")/.."

cmd=run
case "${1:-}" in env|build|conformance|run) cmd=$1; shift ;; -h|--help) sed -n '2,32p' "$0"; exit 0 ;; esac

build=1 reseed=0
passthru=()
for a in "$@"; do
  case "$a" in
    --no-build) build=0 ;;
    --reseed) reseed=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) passthru+=("$a") ;;
  esac
done

command -v node >/dev/null || { echo "node (22+) is required" >&2; exit 1; }
crystal=${BENCH_CRYSTAL:-crystal}
shards=${BENCH_SHARDS:-shards}
runner=benchmark/driver/run.mjs
db=benchmark/db/bench.sqlite3

if [ "$cmd" = env ]; then exec node "$runner" env; fi

build_apps() {
  command -v "$crystal" >/dev/null || { echo "no Crystal compiler ($crystal): set BENCH_CRYSTAL" >&2; return 1; }
  local failed=0 name dir flags
  while IFS=$'\t' read -r name dir flags; do
    echo "== build $name" >&2
    (
      cd "benchmark/apps/$dir"
      # the shard.lock files pin every version; --frozen refuses to change them
      $shards install --frozen --ignore-crystal-version >&2 || $shards install --ignore-crystal-version >&2
      mkdir -p bin
      # shellcheck disable=SC2086
      $crystal build --release --no-debug $flags -o "bin/$name" src/app.cr >&2
    ) || { echo "SKIP $name: build failed" >&2; failed=1; }
  done < <(node "$runner" plan "${passthru[@]}")
  if [ "$failed" = 1 ] && [ -n "${BENCH_REQUIRED:-}" ]; then return 1; fi
  return 0
}

if [ "$cmd" = build ]; then build_apps; exit $?; fi

if [ "$reseed" = 1 ] || [ ! -f "$db" ]; then benchmark/db/seed.sh "$db" >&2; fi
if [ "$build" = 1 ]; then build_apps; fi
exec node "$runner" "$cmd" "${passthru[@]}"

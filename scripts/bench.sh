#!/usr/bin/env bash
# Azu framework benchmark suite: builds the benchmark apps, checks they answer identically, and measures them.
# Methodology, fairness rules and how to read results: benchmark/README.md
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
#   --allow-skip      measure the apps that work although a requested one cannot be built, started or is not conformant
#                     (default: the run fails and names them; --require-all is accepted and means the default)
#   --no-build        run: use the binaries that exist
#   --reseed          recreate the SQLite database
#   --wait-quiet S    wait up to S seconds (default 300) for the machine to become quiet before refusing; the load
#                     average lags for minutes after a build
#   --allow-errors    accept a run with INVALID rows (non-2xx, socket errors, failed runs); default: exit 4
#   --result-file F   also write the result path to F
#
# Exit status: 0 success; 1 an app or a build failed under --require-all/BENCH_REQUIRED, or an internal error;
# 2 invalid usage; 3 refused because the machine is not quiet; 4 the run finished but has INVALID rows (errors or
# failed runs; see --allow-errors).
#
# Environment: BENCH_CRYSTAL / BENCH_SHARDS name the compiler and shards commands (default crystal, shards).
# Needs: crystal 1.22.1+, wrk, node 22+, sqlite3 CLI, libmagic (Athena), and git access for `shards install`.
# The load generator and the apps share the machine: results are only comparable within one session.
set -euo pipefail
cd "$(dirname "$0")/.."

cmd=run
case "${1:-}" in env|build|conformance|run) cmd=$1; shift ;; -h|--help) sed -n '2,42p' "$0"; exit 0 ;; esac

build=1 reseed=0
passthru=()
for a in "$@"; do
  case "$a" in
    --no-build) build=0 ;;
    --reseed) reseed=1 ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
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
  local plan failed=0 name dir flags
  # not `done < <(...)`: a failing plan must stop the script, and a process substitution hides its exit status
  plan=$(node "$runner" plan ${passthru[@]+"${passthru[@]}"})
  while IFS=$'\t' read -r name dir flags; do
    [ -n "$name" ] || continue
    echo "== build $name" >&2
    # a subshell on the left of || runs with set -e off: every command ends in || exit 1
    (
      cd "benchmark/apps/$dir" || exit 1
      # the shard.lock files pin every version; --frozen refuses to change them
      if [ -n "${BENCH_REQUIRED:-}" ] || [ -n "${CI:-}" ]; then
        # a pin that cannot be honoured is an error, not something to repair silently
        $shards install --frozen --ignore-crystal-version >&2 || exit 1
      elif ! $shards install --frozen --ignore-crystal-version >&2; then
        echo "WARNING: $dir/shard.lock does not match shard.yml; installing without --frozen (the result records the lock hash and changes)" >&2
        $shards install --ignore-crystal-version >&2 || exit 1
      fi
      mkdir -p bin || exit 1
      # shellcheck disable=SC2086
      $crystal build --release --no-debug $flags -o "bin/$name" src/app.cr >&2 || exit 1
    ) || { echo "SKIP $name: build failed" >&2; failed=1; }
  done <<< "$plan"
  if [ "$failed" = 1 ] && [ -n "${BENCH_REQUIRED:-}${CI:-}" ]; then return 1; fi
  return 0
}

if [ "$cmd" = build ]; then build_apps; exit $?; fi

if [ "$reseed" = 1 ] || [ ! -f "$db" ]; then benchmark/db/seed.sh "$db" >&2; fi
if [ "$build" = 1 ]; then build_apps; fi
exec node "$runner" "$cmd" ${passthru[@]+"${passthru[@]}"}

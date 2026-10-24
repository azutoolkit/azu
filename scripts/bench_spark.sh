#!/usr/bin/env bash
# Runs the Spark benchmark suite and writes one JSON result file. See benchmark/spark/README.md.
#
#   scripts/bench_spark.sh [--mode short|full] [--suite sizes,client,server] [--out DIR]
#                          [--compare BASE.json] [--threshold PERCENT]
#
#   --mode        short (a few minutes, 10 repetitions) or full (for a quiet machine; default short)
#   --suite       comma list of: sizes (artifact bytes per commit), client (Chromium), server (Crystal)
#   --out         directory for the result files (default benchmark/spark/results)
#   --compare     afterwards diff the result against BASE.json (benchmark/spark/compare.mjs)
#   --threshold   regression limit for --compare, percent (default 15)
#
# Environment: PLAYWRIGHT_MODULE and CHROMIUM_PATH locate playwright and chromium; BENCH_CRYSTAL is the
# compiler command (default `crystal`; a docker wrapper works) and BENCH_EXEC_PREFIX runs the built
# server binary through the same wrapper; BENCH_PREV_COMMIT is the "previous engine" commit (2c373cd);
# BENCH_REQUIRED=1 turns a skipped suite into a failure. Benchmarks are not part of `crystal spec`.
set -euo pipefail
cd "$(dirname "$0")/.."

mode=short
suites=sizes,client,server
out=benchmark/spark/results
compare=""
threshold=15
need() { [ "$1" -ge 2 ] || { echo "$2 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in --mode|--suite|--out|--compare|--threshold) need "$#" "$1" ;; esac
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --suite) suites="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --compare) compare="$2"; shift 2 ;;
    --threshold) threshold="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
case "$mode" in short|full) ;; *) echo "mode must be short or full" >&2; exit 2 ;; esac

skip() {
  echo "SKIP $1: $2" >&2
  [ "${BENCH_REQUIRED:-}" = 1 ] && exit 1
  return 0
}

if ! command -v node >/dev/null; then echo "node is required" >&2; exit 1; fi
mkdir -p "$out"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
parts=()
echo "load average at start: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime)" >&2

if [[ ",$suites," == *,sizes,* ]]; then
  echo "== sizes" >&2
  node benchmark/spark/sizes.mjs --mode "$mode" --out "$work/sizes.json" --table "$out/spark-$stamp-sizes.md" >/dev/null
  parts+=("$work/sizes.json")
fi

if [[ ",$suites," == *,client,* ]]; then
  echo "== client ($mode)" >&2
  if node -e 'const m=process.env.PLAYWRIGHT_MODULE||"playwright";require(m)' 2>/dev/null; then
    node benchmark/spark/client.mjs --mode "$mode" --out "$work/client.json"
    parts+=("$work/client.json")
  else
    skip client "playwright is not installed (npm i playwright, or set PLAYWRIGHT_MODULE)"
  fi
fi

if [[ ",$suites," == *,server,* ]]; then
  echo "== server ($mode)" >&2
  crystal_cmd=${BENCH_CRYSTAL:-crystal}
  if $crystal_cmd --version >/dev/null 2>&1; then
    mkdir -p benchmark/spark/bin
    $crystal_cmd build --release -o benchmark/spark/bin/spark_server_bench benchmark/spark/server_bench.cr
    BENCH_CRYSTAL_VERSION=$($crystal_cmd --version | head -1) \
      node benchmark/spark/server.mjs --bin "$PWD/benchmark/spark/bin/spark_server_bench" --mode "$mode" --out "$work/server.json"
    parts+=("$work/server.json")
  else
    skip server "no Crystal compiler (set BENCH_CRYSTAL)"
  fi
fi

if [ ${#parts[@]} -eq 0 ]; then echo "nothing was measured" >&2; exit 1; fi
result="$out/spark-$stamp.json"
node benchmark/spark/merge.mjs "$result" "${parts[@]}" >&2
node benchmark/spark/report.mjs "$result" > "$out/spark-$stamp.md"
echo "load average at end: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime)" >&2
echo "$result"

if [ -n "$compare" ]; then
  node benchmark/spark/compare.mjs "$compare" "$result" --threshold "$threshold"
fi

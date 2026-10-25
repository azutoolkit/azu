#!/usr/bin/env bash
# One command: scripts/cql_driver_bench.sh   (DATABASE_URL=postgres://user@host:port/db BENCH_RUNS=5 ...)
# Builds the benchmark twice with --release (with and without the pg shard), then runs pg, native and engine
# alternately BENCH_RUNS times (default 5) and prints the median operations per second per workload.
# Needs a quiet machine: nothing else compiling or running.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DATABASE_URL:?set DATABASE_URL}"
RUNS="${BENCH_RUNS:-5}"
OUT="${BENCH_OUT:-${TMPDIR:-/tmp}/azu_cql_driver_bench}"
mkdir -p "$OUT"
crystal build --release -Dbench_pg -o "$OUT/bench_pg" scripts/cql_driver_bench.cr
crystal build --release -o "$OUT/bench" scripts/cql_driver_bench.cr
: > "$OUT/raw.tsv"
for run in $(seq "$RUNS"); do
  "$OUT/bench_pg" pg >> "$OUT/raw.tsv"
  "$OUT/bench" native >> "$OUT/raw.tsv"
  "$OUT/bench" engine >> "$OUT/raw.tsv"
done
sort -t$'\t' -k2,2 -k1,1 -k3,3n "$OUT/raw.tsv" | awk -F'\t' '
  { key = $2 "\t" $1; v[key] = v[key] " " $3; n[key]++ }
  END { for (k in v) { split(v[k], a, " "); m = asort(a); printf "%s\tmedian %d\t(runs:%s)\n", k, a[int((m + 1) / 2)], v[k] } }' | sort

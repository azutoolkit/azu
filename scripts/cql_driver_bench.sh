#!/usr/bin/env bash
# One command: scripts/cql_driver_bench.sh   (DATABASE_URL=postgres://user@host:port/db BENCH_RUNS=5 ...)
# Builds the benchmark twice with --release (with and without the pg shard), then runs pg, native and engine
# alternately BENCH_RUNS times (default 5) and prints the median operations per second per workload.
# Needs a quiet machine: nothing else compiling or running.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DATABASE_URL:?set DATABASE_URL}"
# Refuse anything that is not a local test database (the benchmark drops and creates a table).
host="$(printf '%s' "$DATABASE_URL" | sed -E 's#^[a-z]+://([^@/]*@)?(\[[^]]*\]|[^:/?]*).*#\2#')"
database="$(printf '%s' "$DATABASE_URL" | sed -E 's#^[a-z]+://[^/]*/([^?]*).*#\1#')"
case "$host" in ""|localhost|127.0.0.1|"[::1]") ;; *) [ "${BENCH_ALLOW_REMOTE:-}" = 1 ] || { echo "refusing non-local host '$host' (BENCH_ALLOW_REMOTE=1 to allow)" >&2; exit 2; } ;; esac
case "$database" in *bench*|*test*) ;; *) [ "${BENCH_I_KNOW:-}" = 1 ] || { echo "refusing database '$database': name must contain bench or test (BENCH_I_KNOW=1 to allow)" >&2; exit 2; } ;; esac
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
# Median per driver and workload with plain sort/awk (no gawk-only functions).
cut -f1,2 "$OUT/raw.tsv" | sort -u | while IFS=$'\t' read -r driver workload; do
  values="$(awk -F'\t' -v d="$driver" -v w="$workload" '$1 == d && $2 == w { print $3 }' "$OUT/raw.tsv" | sort -n)"
  count="$(printf '%s\n' "$values" | wc -l)"
  median="$(printf '%s\n' "$values" | sed -n "$(( (count + 1) / 2 ))p")"
  printf '%s\t%s\tmedian %s\t(runs: %s)\n' "$workload" "$driver" "$median" "$(printf '%s' "$values" | tr '\n' ' ')"
done | sort

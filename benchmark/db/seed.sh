#!/usr/bin/env bash
# Creates benchmark/db/bench.sqlite3 (1000 rows) for the DB scenarios. Same file for every framework.
#   benchmark/db/seed.sh [path]
set -euo pipefail
db=${1:-"$(dirname "$0")/bench.sqlite3"}
rm -f "$db" "$db-wal" "$db-shm"
command -v sqlite3 >/dev/null || { echo "sqlite3 CLI is required" >&2; exit 1; }
sqlite3 "$db" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, value INTEGER NOT NULL);
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000)
INSERT INTO items (id, name, value) SELECT n, 'item-' || n, n * 3 FROM seq;
SQL
echo "$db"

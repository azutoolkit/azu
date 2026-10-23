#!/usr/bin/env bash
# Runs the browser test of the Spark client (reconnect, rehydration, queue, heartbeat).
#
#   spec/browser/run.sh
#
# Needs crystal, node and playwright with chromium (npm i playwright && npx playwright install
# chromium). Without them it prints SKIP and exits 0; SPARK_BROWSER_REQUIRED=1 makes that a failure.
# The app is playground/spark_demo/app.cr; override how it starts with SPARK_SERVER_CMD (it gets
# PORT, HOST and SPARK_HEARTBEAT_INTERVAL in its environment), the browser with CHROMIUM_PATH and
# the module with PLAYWRIGHT_MODULE. It is not part of `crystal spec`.
set -euo pipefail
cd "$(dirname "$0")/../.."
if ! command -v node >/dev/null; then
  echo "SKIP spark browser test: node is not installed"
  [ "${SPARK_BROWSER_REQUIRED:-}" = 1 ] && exit 1 || exit 0
fi
exec node spec/browser/spark_reconnect.cjs

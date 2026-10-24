#!/usr/bin/env bash
# Runs the browser tests of the Spark client (reconnect, rehydration, queue, heartbeat; event delivery; hidden-tab idle, live region; compressed frames; patch engine).
#
#   spec/browser/run.sh
#
# Needs crystal, node and playwright with chromium (npm i playwright && npx playwright install
# chromium). Without them it prints SKIP and exits 0; SPARK_BROWSER_REQUIRED=1 makes that a failure.
# The app is playground/spark_demo/app.cr; override how it starts with SPARK_SERVER_CMD (it gets
# PORT, HOST and SPARK_HEARTBEAT_INTERVAL=1 in its environment; a docker wrapper must forward them, and
# should stop its container when the command ends: the test kills only its own process group), the browser with CHROMIUM_PATH and
# the module with PLAYWRIGHT_MODULE. It is not part of `crystal spec`.
set -euo pipefail
cd "$(dirname "$0")/../.."
if ! command -v node >/dev/null; then
  echo "SKIP spark browser test: node is not installed"
  [ "${SPARK_BROWSER_REQUIRED:-}" = 1 ] && exit 1 || exit 0
fi
node spec/browser/spark_reconnect.cjs
node spec/browser/spark_delivery.cjs
node spec/browser/spark_idle.cjs
node spec/browser/spark_compress.cjs
exec node spec/browser/spark_patch.cjs

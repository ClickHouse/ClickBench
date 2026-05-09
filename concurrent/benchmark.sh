#!/bin/bash
#
# Concurrent ClickBench: full end-to-end run for one backend.
#
# 1. Delegates to ../$backend/benchmark.sh to install + load the `hits` table
#    (this also runs the standard sequential query benchmark as a side-effect).
# 2. Runs the concurrent driver via ./run.sh.
#
# Usage:   ./benchmark.sh {clickhouse|starrocks}
# Tunable: CONCURRENCY (default 10) DURATION (default 600) WARMUP (default 30)

set -e

if [ -z "$1" ]; then
  echo "usage: $0 {clickhouse|starrocks}" >&2
  exit 1
fi
BACKEND="$1"

case "$BACKEND" in
  clickhouse|starrocks) ;;
  *) echo "Unknown backend: $BACKEND" >&2; exit 1 ;;
esac

# Install + load (skipped if data is already loaded, by the upstream script)
(cd "../$BACKEND" && ./benchmark.sh)

# Concurrent run
./run.sh "$BACKEND"

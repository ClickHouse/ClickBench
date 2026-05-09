#!/bin/bash
#
# Concurrent ClickBench: run the concurrent driver against an already-loaded
# `hits` table. Use ../clickhouse/benchmark.sh or ../starrocks/benchmark.sh
# first to install and load data.
#
# Usage:   ./run.sh {clickhouse|starrocks}
# Tunable: CONCURRENCY (default 10) DURATION (default 600) WARMUP (default 30)

set -e

if [ -z "$1" ]; then
  echo "usage: $0 {clickhouse|starrocks}" >&2
  exit 1
fi
BACKEND="$1"
CONCURRENCY="${CONCURRENCY:-10}"
DURATION="${DURATION:-600}"
WARMUP="${WARMUP:-30}"
HOST="${HOST:-127.0.0.1}"

case "$BACKEND" in
  clickhouse)
    QUERIES=queries-clickhouse.sql
    ;;
  starrocks)
    QUERIES=queries-starrocks.sql
    if ! python3 -c "import pymysql" 2>/dev/null; then
      python3 -m pip install --quiet pymysql || pip3 install --quiet pymysql
    fi
    ;;
  *)
    echo "Unknown backend: $BACKEND" >&2
    exit 1
    ;;
esac

python3 run.py \
  --backend "$BACKEND" \
  --host "$HOST" \
  --queries "$QUERIES" \
  --concurrency "$CONCURRENCY" \
  --duration "$DURATION" \
  --warmup "$WARMUP" \
  --output-json "result-$BACKEND.json" \
  2>&1 | tee "log-$BACKEND.txt"

#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
export BENCH_RESTARTABLE=no
# Each query runs a fresh zpq process: there is no server and no shared
# scheduler across connections, so the concurrent-QPS test would only
# oversubscribe the machine. Skip it by default, like DuckDB (Parquet);
# override BENCH_CONCURRENT_DURATION to re-enable. See issue #946.
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"
exec ../lib/benchmark-common.sh

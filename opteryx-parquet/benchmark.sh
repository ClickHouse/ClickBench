#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
# Long-lived query server (server.py). Restartable: the driver stops it, drops
# caches and starts it again before every query, so try 1 is a cold process;
# tries 2-3 hit the same process. Durable: the data is Parquet on disk, nothing
# lives in process memory, so ./load is not re-run.
export BENCH_RESTARTABLE=yes
export BENCH_DURABLE=yes
# Concurrent-QPS test stays off for now: server.py serves one request at a
# time, so N connections would measure a queue, not throughput.
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"
exec ../lib/benchmark-common.sh

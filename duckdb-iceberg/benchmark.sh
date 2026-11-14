#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
# Embedded engine: no daemon to restart, the data is in the storage.
export BENCH_RESTARTABLE=no
# Single-process engine: each query forks a fresh full-machine process with no
# shared scheduler across connections, so the concurrent-QPS test only
# oversubscribes RAM rather than measuring throughput. See issue #946.
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"
exec ../lib/benchmark-common.sh

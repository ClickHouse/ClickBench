#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
# Embedded engine: no daemon to restart, one process per query.
export BENCH_RESTARTABLE=no
# Single-process engine: each query forks a fresh full-machine process, so
# the concurrent-QPS test would only oversubscribe RAM (see issue #946).
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"
exec ../lib/benchmark-common.sh

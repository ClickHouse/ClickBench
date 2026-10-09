#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
export BENCH_RESTARTABLE=no
# See chdb/benchmark.sh.
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"
../lib/benchmark-common.sh

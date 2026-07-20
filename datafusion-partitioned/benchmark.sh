#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
export BENCH_RESTARTABLE=no
# skip concurrent_qps tests by default as datafusion-cli is configured
# for single user/single process usage
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"
exec ../lib/benchmark-common.sh

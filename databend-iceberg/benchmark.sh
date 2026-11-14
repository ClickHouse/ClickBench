#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
export BENCH_CHECK_TIMEOUT=600
exec ../lib/benchmark-common.sh

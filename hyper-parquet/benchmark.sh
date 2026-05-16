#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
export BENCH_DURABLE=yes
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

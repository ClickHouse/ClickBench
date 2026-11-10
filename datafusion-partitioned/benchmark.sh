#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

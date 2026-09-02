#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_DURABLE=yes
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh

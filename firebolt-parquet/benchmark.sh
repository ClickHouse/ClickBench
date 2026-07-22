#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_DURABLE=no
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

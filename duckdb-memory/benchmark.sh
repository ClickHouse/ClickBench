#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_DURABLE=no
exec ../lib/benchmark-common.sh

#!/bin/bash
set -e

export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_DURABLE=yes
exec ../lib/benchmark-common.sh

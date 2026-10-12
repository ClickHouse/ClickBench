#!/bin/bash
set -eu
cd "$(dirname "$0")"
if [ ! -f ../lib/benchmark-common.sh ]; then
    echo 'Copy this directory to a ClickBench checkout as duckflight/ first; see README.md.' >&2
    exit 1
fi
export BENCH_DOWNLOAD_SCRIPT=download-hits-parquet-single
export BENCH_RESTARTABLE=yes
export BENCH_DURABLE=yes
exec ../lib/benchmark-common.sh

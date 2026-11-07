#!/bin/bash
set -eu
cd "$(dirname "$0")"
export BENCH_DOWNLOAD_SCRIPT=download-hits-parquet-single
export BENCH_RESTARTABLE=yes BENCH_DURABLE=yes
# Use three executions per query and the default concurrency settings.
exec flock -n .benchmark.lock ../lib/benchmark-common.sh

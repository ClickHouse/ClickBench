#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
# Durable: the server only holds a lazy scan over the Parquet data on disk,
# and rebuilds it when it starts. The driver restarts it and drops caches
# before each cold run, and doesn't need to re-run ./load.
export BENCH_DURABLE=yes
exec ../lib/benchmark-common.sh

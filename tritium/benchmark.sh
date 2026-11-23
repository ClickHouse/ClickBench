#!/bin/bash
# ClickBench's driver (lib/benchmark-common.sh) with its defaults: a server (BENCH_RESTARTABLE=yes), stopped, the
# caches dropped and started again before each query's first run; the data on disk (BENCH_DURABLE=yes), read in place.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
exec ../lib/benchmark-common.sh

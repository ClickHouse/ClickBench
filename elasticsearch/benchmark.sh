#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# Source data is gzipped NDJSON, fetched directly inside ./load.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh

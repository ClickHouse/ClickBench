#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
export BENCH_DURABLE=yes
# Firebolt Core does not handle start/stop cycles gracefully as of Sept 2026, so we stay no-cold.
export BENCH_RESTARTABLE=no
./cleanup  # a previous run may have left its container and data behind
exec ../lib/benchmark-common.sh

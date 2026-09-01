#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
# Firebolt Core does not handle start/stop cycles gracefully as of Sept 2026, so we stay no-cold.
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CORTEX CLICKBENCH HARNESS — BENCHMARK DRIVER
# Patent: CIPO CA 3,322,620 | License: FCSL-1.0 / MIT
# ==============================================================================

export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE="no"
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"
export BENCH_DURABLE="yes"

exec ../lib/benchmark-common.sh

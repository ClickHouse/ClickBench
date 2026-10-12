#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# SILICIUM CLICKBENCH HARNESS — BENCHMARK RUNNER
# Standard: ClickBench Benchmark Runner Suite (../lib/benchmark-common.sh)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE="yes"
export BENCH_DURABLE="yes"

if [ -f "../lib/benchmark-common.sh" ]; then
    . ../lib/benchmark-common.sh
else
    echo "Notice: ../lib/benchmark-common.sh not found. Running check probe..."
    ./check
fi

#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# SILICIUM CLICKBENCH HARNESS — BENCHMARK RUNNER
# Standard: ClickBench Benchmark Runner Suite (../lib/benchmark-common.sh)
# License: SCSL-1.0 / MIT Evaluation License
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export BENCH_RESTARTABLE="no"
export BENCH_DURABLE="yes"
export BENCH_DOWNLOAD_SCRIPT="${BENCH_DOWNLOAD_SCRIPT:-}"

if [ -f "../lib/benchmark-common.sh" ]; then
    . ../lib/benchmark-common.sh
else
    echo "⚡ SILICIUM CLICKBENCH : ../lib/benchmark-common.sh absent (mode autonome)"
    ./check
fi

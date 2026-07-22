#!/bin/bash
set -e

export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_DURABLE=yes
export BENCH_RESTARTABLE=no
export BENCH_CONCURRENT_DURATION=0

../lib/benchmark-common.sh || true

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
echo ""
echo "=== generic-smoke ==="
"${SCRIPT_DIR}/generic-smoke.sh"

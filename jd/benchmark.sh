#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
export BENCH_DURABLE=yes
export BENCH_RESTARTABLE=no
# Single-process engine: each query forks a fresh ijconsole with no shared
# scheduler across connections, so the concurrent-QPS test only
# oversubscribes RAM rather than measuring throughput. Skip it by default;
# override BENCH_CONCURRENT_DURATION to re-enable. See issue #946.
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"
exec ../lib/benchmark-common.sh

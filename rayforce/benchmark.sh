#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
# IPC server: restarts make cold runs cold, and the concurrent test hits one process.
export BENCH_RESTARTABLE=yes
export BENCH_DURABLE=yes
# Every start opens the table, which takes up to about a minute.
export BENCH_CHECK_TIMEOUT="${BENCH_CHECK_TIMEOUT:-1800}"
exec ../lib/benchmark-common.sh

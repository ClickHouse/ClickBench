#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
# Rayforce runs as an IPC server here (./start), so the stop/drop_caches/start
# cold cycle is meaningful and the concurrent-QPS test hits a shared process.
export BENCH_RESTARTABLE=yes
export BENCH_DURABLE=yes
# Opening the splayed table validates every column file and loads the symbol
# dictionary; at 100M rows that takes minutes, and it happens on every restart,
# so the readiness probe needs a much longer window than the 300s default.
export BENCH_CHECK_TIMEOUT="${BENCH_CHECK_TIMEOUT:-1800}"
exec ../lib/benchmark-common.sh

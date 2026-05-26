#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-json"
export BENCH_DURABLE=yes
# queries are LogsQL, not SQL.
export BENCH_QUERIES_FILE="queries.logsql"
exec ../lib/benchmark-common.sh

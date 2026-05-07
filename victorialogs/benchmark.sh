#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# victorialogs ingests gzipped NDJSON; ./load fetches it directly.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_RESTARTABLE=yes
# queries are LogsQL, not SQL.
export BENCH_QUERIES_FILE="queries.logsql"
exec ../lib/benchmark-common.sh

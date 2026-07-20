#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-json"
# queries are LogsQL, not SQL.
export BENCH_QUERIES_FILE="queries.logsql"
exec ../lib/benchmark-common.sh

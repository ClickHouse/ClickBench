#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-json"
# queries.sql contains LogsQL, not SQL.
export BENCH_QUERIES_FILE="queries.sql"
exec ../lib/benchmark-common.sh

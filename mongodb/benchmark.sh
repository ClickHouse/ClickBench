#!/bin/bash
# This system runs aggregation pipelines (queries.sql, Extended JSON one per line) rather than SQL.
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"
export BENCH_QUERIES_FILE="queries.sql"
exec ../lib/benchmark-common.sh

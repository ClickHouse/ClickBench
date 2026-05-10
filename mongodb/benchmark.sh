#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh. MongoDB uses
# aggregation pipelines (queries.txt, EJSON one-per-line) rather than SQL.
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"
export BENCH_DURABLE=yes
export BENCH_QUERIES_FILE="queries.txt"
exec ../lib/benchmark-common.sh

#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
export BENCH_RESTARTABLE=no
export BENCH_CONCURRENT_DURATION=0
export BENCH_QUERIES_FILE="../chdb/queries.sql"
export DIAG_REPLICA=A
export DIAG_ORDER=forward
exec ../lib/benchmark-common.sh

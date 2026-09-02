#!/bin/bash
# Set CRATEDB_MODE=tuned to use create-tuned.sql + queries-tuned.sql.
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"

if [ "${CRATEDB_MODE:-default}" = "tuned" ]; then
    export BENCH_QUERIES_FILE="queries-tuned.sql"
fi

exec ../lib/benchmark-common.sh

#!/bin/bash
# The queries are ES|QL, one per line.
export BENCH_QUERIES_FILE="queries.txt"
# Recovering the shards of a large index after a restart takes a while.
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh "$@"

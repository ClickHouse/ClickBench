#!/bin/bash
# The queries are MongoDB aggregation pipelines in mongosh syntax, one per line.
export BENCH_QUERIES_FILE="queries.js"
exec ../lib/benchmark-common.sh "$@"

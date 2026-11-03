#!/bin/bash
# The queries are the MongoDB aggregation pipelines (../mongodb/queries.js).
export BENCH_QUERIES_FILE="queries.js"
exec ../lib/benchmark-common.sh "$@"

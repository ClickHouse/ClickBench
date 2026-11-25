#!/bin/bash
# The same as ../elasticsearch (whose scripts are symlinked here), but the
# index template disables _source, so the documents cannot be retrieved.
export BENCH_QUERIES_FILE="queries.txt"
# Recovering the shards of a large index after a restart takes a while.
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh "$@"

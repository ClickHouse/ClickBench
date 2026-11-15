#!/bin/bash
# The queries are OpenSearch query DSL requests (JSON), one per line.
export BENCH_QUERIES_FILE="queries.json"
# Recovering the shards of a large index after a restart takes a while.
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh "$@"

#!/bin/bash
# Quickwit has no SQL: the queries are search requests in Quickwit's native
# JSON query language, one per line of queries.json ("null" for a query that
# Quickwit cannot express; the driver records it as null).
export BENCH_QUERIES_FILE="queries.json"
exec ../lib/benchmark-common.sh "$@"

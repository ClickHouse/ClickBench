#!/bin/bash
# DuckDB is embedded: there is no server to restart between the cold runs,
# only the page cache is dropped.
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh "$@"

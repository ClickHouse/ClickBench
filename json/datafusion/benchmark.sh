#!/bin/bash
# DataFusion is embedded: every query runs in its own process over the Parquet
# files, there is no server to restart between the cold runs, only the page
# cache is dropped.
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh "$@"

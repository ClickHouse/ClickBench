#!/bin/bash
# Spark runs in-process (local mode): every query starts its own PySpark
# session, there is no server to restart between the cold runs, only the page
# cache is dropped.
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh "$@"

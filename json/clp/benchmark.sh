#!/bin/bash
# CLP (clp-json) is a set of Docker Compose services plus a Presto cluster:
# ./stop and ./start restart all of them before the cold run of every query.
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh "$@"

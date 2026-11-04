#!/bin/bash
# A single-node YDB server (a storage node and a database node), restarted
# before the cold run of every query.
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh "$@"

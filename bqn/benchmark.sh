#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_DURABLE=yes
export BENCH_RESTARTABLE=no
# The 43 queries live as BQN functions in queries.bqn; queries.idx is a
# 43-line file (1..43) that the driver pipes into ./query for dispatch.
export BENCH_QUERIES_FILE=queries.idx
exec ../lib/benchmark-common.sh

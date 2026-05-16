#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
# Spark runs in-process per query — restart between queries is meaningless
# (and would re-download nothing). Skip restart.
export BENCH_DURABLE=yes
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

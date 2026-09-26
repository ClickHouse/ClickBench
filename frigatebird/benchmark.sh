#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# Frigatebird is an embedded columnar database, similar in shape to
# duckdb: no daemon, data persists on disk between query invocations.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_DURABLE=yes
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

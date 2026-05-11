#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_DURABLE=yes
export PGHOST="/tmp"
export PGUSER=postgres
export PGDATABASE=postgres

exec ../lib/benchmark-common.sh

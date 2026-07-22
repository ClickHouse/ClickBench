#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export PGHOST="/tmp"
export PGUSER=postgres
export PGDATABASE=postgres
exec ../lib/benchmark-common.sh

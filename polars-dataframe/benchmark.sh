#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE=no
# polars runs Python expressions directly (server eval()s them); queries.sql
# is kept for cross-system reference but the actual workload is in queries.py.
export BENCH_QUERIES_FILE=queries.py
exec ../lib/benchmark-common.sh

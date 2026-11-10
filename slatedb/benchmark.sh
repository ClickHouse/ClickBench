#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
# Embedded engine: no daemon to restart, one process per query.
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

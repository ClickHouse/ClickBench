#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# TiDB Lightning loads from <db>.<table>.csv files; we use the CSV download.
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh

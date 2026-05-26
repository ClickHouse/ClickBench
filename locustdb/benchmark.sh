#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
export BENCH_DURABLE=yes
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh

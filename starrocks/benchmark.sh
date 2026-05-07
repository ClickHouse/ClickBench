#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh

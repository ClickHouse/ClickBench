#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# Empty BENCH_DOWNLOAD_SCRIPT: install fetches hits.parquet itself,
# because the container needs the file bind-mounted at start time
# (before lib's bench_download step runs).
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh

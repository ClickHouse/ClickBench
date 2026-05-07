#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# parseable ingests gzipped NDJSON; ./load fetches it directly.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh

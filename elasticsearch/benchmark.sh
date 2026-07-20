#!/bin/bash
# Source data is gzipped NDJSON, fetched directly inside ./load.
export BENCH_DOWNLOAD_SCRIPT=""
exec ../lib/benchmark-common.sh

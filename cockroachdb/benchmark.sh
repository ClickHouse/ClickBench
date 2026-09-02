#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
# cockroach replays its WAL on each restart; after the 60 GB+ IMPORT
# that takes long enough that the lib's default 300 s check window
# times out before SELECT 1 succeeds again. 900 s covers it.
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh

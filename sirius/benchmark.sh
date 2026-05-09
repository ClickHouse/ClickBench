#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE=no
# sirius's server.py initializes CUDA / cuDF on startup which can take
# several minutes on a cold instance; the lib's 300 s default timed out
# before /health came up. 900 s leaves headroom for that warm-up.
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh

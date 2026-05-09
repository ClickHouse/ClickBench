#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE=no
# sirius's server.py initializes CUDA / cuDF on startup which can take
# several minutes on a cold instance — 900 s wasn't enough on the
# c6a.4xlarge runs we've seen. Bump again.
export BENCH_CHECK_TIMEOUT=1800
exec ../lib/benchmark-common.sh

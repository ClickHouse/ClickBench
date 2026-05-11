#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
export BENCH_DURABLE=yes
# omnisci/core-os-cpu's first cold start runs schema migrations, opens
# its catalog, and binds Thrift ports; 600 s wasn't enough on the first
# Docker rewrite run, so allow up to 15 minutes.
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh

#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
# omnisci/core-os-cpu's first cold start runs schema migrations, opens
# its catalog, and binds Thrift ports; 600 s wasn't enough on the first
# Docker rewrite run, so allow up to 15 minutes.
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh

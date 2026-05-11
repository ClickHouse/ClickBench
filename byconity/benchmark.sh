#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"
export BENCH_DURABLE=yes
# byconity boots a chain of containers (fdb -> tso -> server -> workers
# / daemon-manager). Each later step waits up to 600s for its
# dependency, so the worst-case cold start is several minutes; the
# lib's 300s default has timed out before server is up.
export BENCH_CHECK_TIMEOUT=1200
exec ../lib/benchmark-common.sh

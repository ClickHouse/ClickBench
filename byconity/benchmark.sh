#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"
export BENCH_DURABLE=yes
# byconity boots a chain of containers (fdb -> tso -> server -> workers
# / daemon-manager). Each later step waits up to 600s for its
# dependency, so the worst-case cold start is several minutes; the
# lib's 300s default has timed out before server is up.
export BENCH_CHECK_TIMEOUT=1200
# After firecracker snapshot+restore the cluster's
# internal connections (brpc/gossip) are stale; ./start's
# shallow health probe doesn't notice and short-circuits.
# Tell the playground agent to ./stop the cluster before
# ./start so the next bring-up is from a clean state.
export PLAYGROUND_RESTART_AFTER_RESTORE_SNAPSHOT=yes
exec ../lib/benchmark-common.sh

#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# Quickwit takes Elasticsearch-format JSON queries; the load script fetches
# hits.json.gz directly so no shared download-hits-* script applies.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_DURABLE=yes
export BENCH_QUERIES_FILE="queries.json"
# After firecracker snapshot+restore the cluster's
# internal connections (brpc/gossip) are stale; ./start's
# shallow health probe doesn't notice and short-circuits.
# Tell the playground agent to ./stop the cluster before
# ./start so the next bring-up is from a clean state.
export PLAYGROUND_RESTART_AFTER_RESTORE_SNAPSHOT=yes
exec ../lib/benchmark-common.sh

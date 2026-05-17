#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# TiDB Lightning loads from <db>.<table>.csv files; we use the CSV download.
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
export BENCH_DURABLE=yes
# Skip the pre-snapshot ./stop+./start cycle: the loaded
# state lives only in the daemon's process memory (in-process
# DataFrame, JVM heap caches) and stopping wipes it. The
# playground agent reads this and snapshots the running daemon.
export PLAYGROUND_SKIP_RESTART_BEFORE_SNAPSHOT=yes
exec ../lib/benchmark-common.sh

#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_DURABLE=no
# polars runs Python expressions directly (server eval()s them).
# queries.sql holds those Python expressions, one per line, so the
# default BENCH_QUERIES_FILE=queries.sql in lib/benchmark-common.sh
# picks them up unchanged.
# Skip the pre-snapshot ./stop+./start cycle: the loaded
# state lives only in the daemon's process memory (in-process
# DataFrame, JVM heap caches) and stopping wipes it. The
# playground agent reads this and snapshots the running daemon.
export PLAYGROUND_SKIP_RESTART_BEFORE_SNAPSHOT=yes
exec ../lib/benchmark-common.sh

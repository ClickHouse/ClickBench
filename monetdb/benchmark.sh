#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"

# The first restart after the load has to replay the write-ahead log
# that `COPY INTO` wrote. That log is about as large as the ingested
# TSV — in a scaled-down run here, 200k rows of hits.tsv left a 142 MB
# `sql_logs/sql/log.1` next to only 86 MB of BATs — so on the full
# dataset the first `./start` can take far longer than the 300 s
# default before `mclient` can connect. Every later cold cycle is
# quick: a clean shutdown checkpoints the log and truncates it.
export BENCH_CHECK_TIMEOUT=3600

exec ../lib/benchmark-common.sh

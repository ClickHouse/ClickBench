#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# Quickwit takes Elasticsearch-format JSON queries.
export BENCH_DOWNLOAD_SCRIPT="download-hits-json"
export BENCH_DURABLE=yes
export BENCH_QUERIES_FILE="queries.json"
exec ../lib/benchmark-common.sh

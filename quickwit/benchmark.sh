#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# Quickwit takes Elasticsearch-format JSON queries; the load script fetches
# hits.json.gz directly so no shared download-hits-* script applies.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_DURABLE=yes
export BENCH_QUERIES_FILE="queries.json"
exec ../lib/benchmark-common.sh

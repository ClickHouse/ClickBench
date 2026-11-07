#!/bin/bash
# The source data is NDJSON: the pre-decompressed hits.json on the Playground;
# elsewhere ./load downloads hits.json.gz itself, as in ../elasticsearch.
export BENCH_DOWNLOAD_SCRIPT="download-hits-json"
# The queries are OpenSearch search requests (query DSL), one per line.
export BENCH_QUERIES_FILE="queries.json"
# Recovering the shard of a large index after a restart takes a while.
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh

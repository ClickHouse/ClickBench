#!/bin/bash
# The source data is NDJSON: the pre-decompressed hits.json on the Playground;
# elsewhere ./load downloads hits.json.gz itself, as in ../elasticsearch.
export BENCH_DOWNLOAD_SCRIPT="download-hits-json"
# Recovering the shard of a large index after a restart takes a while.
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh

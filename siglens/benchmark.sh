#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-json"
export BENCH_DURABLE=yes
# queries are SPL/Splunk QL, not SQL.
export BENCH_QUERIES_FILE="queries.spl"
exec ../lib/benchmark-common.sh

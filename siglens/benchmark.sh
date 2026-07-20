#!/bin/bash
# siglens ingests its own gzipped NDJSON; ./load fetches it directly.
export BENCH_DOWNLOAD_SCRIPT=""
# queries are SPL/Splunk QL, not SQL.
export BENCH_QUERIES_FILE="queries.sql"
exec ../lib/benchmark-common.sh

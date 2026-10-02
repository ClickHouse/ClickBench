#!/bin/bash
set -euo pipefail

# Apache Kudu is a durable shared server, but restarting catalogd between
# queries loses the in-memory Impala catalog used by this single-node setup.
# We therefore flush only the OS page cache and mark the result no-cold.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE=no
export BENCH_DURABLE=yes
export BENCH_TRIES=3
export BENCH_QUERIES_FILE="queries.sql"
export BENCH_CHECK_TIMEOUT=900
export BENCH_CONCURRENT_CONNECTIONS=10
export BENCH_CONCURRENT_DURATION=600
export KUDU_LOAD_BUCKETS="${KUDU_LOAD_BUCKETS:-10}"

exec ../lib/benchmark-common.sh

#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
# Skip the concurrent-QPS phase: this system exists only for the per-query
# A/B of https://github.com/ClickHouse/ClickHouse/issues/114640.
export BENCH_CONCURRENT_DURATION=0
exec ../lib/benchmark-common.sh

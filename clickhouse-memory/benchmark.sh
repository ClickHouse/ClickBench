#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
# A Memory table lives in the server's heap and nothing is written to
# /var/lib/clickhouse, so the restart before every cold query wipes it. The
# driver therefore re-runs ./load each time and charges the reload to the
# cold try — same contract as duckdb-memory.
export BENCH_DURABLE=no
exec ../lib/benchmark-common.sh

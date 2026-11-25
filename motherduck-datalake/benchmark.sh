#!/bin/bash
# MotherDuck (data lake) entry for the shared ClickBench driver
# (../lib/benchmark-common.sh).
#
# Like clickhouse-datalake / duckdb-datalake, the data stays in S3: ./load only
# creates a VIEW over the public hits.parquet in a MotherDuck database, and
# every query is executed by the remote Duckling reading S3 directly. The
# benchmark VM is a thin DuckDB Python client on an `md:` connection.

# Accept either the DuckDB-native lowercase var (what the client reads) or
# the SDK-style uppercase one.
export motherduck_token="${motherduck_token:-${MOTHERDUCK_TOKEN:-}}"

# Data is read directly from S3, no local download.
export BENCH_DOWNLOAD_SCRIPT=""

# No local daemon: the engine is remote, so the stop/start/check cold-cycle
# would do nothing (and bench_wait_stopped would burn 60s per query because
# ./check keeps succeeding against the cloud).
export BENCH_RESTARTABLE=no

# The view persists in MotherDuck across client restarts.
export BENCH_DURABLE=yes

# Each ./query opens a fresh md: connection (network handshake + catalog
# fetch), so concurrent-QPS workers forking ./query would mostly measure
# client-side connection setup. Use the motherduck entry's worker instead:
# each of the concurrent connections keeps one md:clickbench_datalake
# connection open for the whole window. See issue #946.
export MOTHERDUCK_DATABASE=clickbench_datalake
export BENCH_CONCURRENT_WORKER=../motherduck/concurrent-worker

exec ../lib/benchmark-common.sh

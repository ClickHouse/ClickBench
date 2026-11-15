#!/bin/bash
# MotherDuck (managed DuckLake) entry for the shared ClickBench driver
# (../lib/benchmark-common.sh).
#
# ./load creates an empty MotherDuck-managed DuckLake database and copies the
# public hits.parquet from S3 into it, so the table is backed by DuckLake's own
# parquet files in MotherDuck-managed storage (not the source files adopted
# in place). Queries run on the remote Duckling. The benchmark VM is a thin
# DuckDB Python client on an `md:` connection.

# Accept either the DuckDB-native lowercase var (what the client reads) or
# the SDK-style uppercase one.
export motherduck_token="${motherduck_token:-${MOTHERDUCK_TOKEN:-}}"

# Nothing is fetched onto the client: ./load copies from S3 server-side.
export BENCH_DOWNLOAD_SCRIPT=""

# No local daemon: the engine is remote, so the stop/start/check cold-cycle
# would do nothing (and bench_wait_stopped would burn 60s per query because
# ./check keeps succeeding against the cloud).
export BENCH_RESTARTABLE=no

# The DuckLake data persists in MotherDuck across client restarts.
export BENCH_DURABLE=yes

# Each ./query opens a fresh md: connection, so the concurrent-QPS workers
# would mostly measure connection setup. Skip by default; override
# BENCH_CONCURRENT_DURATION to re-enable. See issue #946.
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"

exec ../lib/benchmark-common.sh

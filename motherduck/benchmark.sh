#!/bin/bash
# MotherDuck entry for the shared ClickBench driver (../lib/benchmark-common.sh).
#
# MotherDuck is a managed, serverless cloud service built on DuckDB. The
# "server" is MotherDuck's cloud; the benchmark VM is only a thin client
# running the DuckDB Python client against an `md:` connection.

# Accept either the DuckDB-native lowercase var (what the client reads) or
# the SDK-style uppercase one used by other cloud entries in the harness.
export motherduck_token="${motherduck_token:-${MOTHERDUCK_TOKEN:-}}"

# Empty: the data lives in MotherDuck cloud. ./load CTAS'es directly from the
# canonical ClickBench parquet on S3 into the cloud database, so there is
# nothing to fetch onto the client VM.
export BENCH_DOWNLOAD_SCRIPT=""

# No local daemon. The engine is remote, so restarting the client process and
# dropping the client's OS page cache does nothing to MotherDuck, and
# bench_wait_stopped would burn its full 60s timeout on every query because
# ./check keeps succeeding against the cloud. Skip the stop/start/check
# cold-cycle; MotherDuck is inherently "no-cold" (see tags in template.json).
export BENCH_RESTARTABLE=no

# Data is durable in MotherDuck cloud across client restarts — no reload
# between queries.
export BENCH_DURABLE=yes

# Each ./query opens a fresh Python -> DuckDB -> md: connection (network
# handshake + catalog fetch), so the concurrent-QPS workers would mostly
# measure cloud connection setup rather than steady-state throughput. Skip by
# default; override BENCH_CONCURRENT_DURATION to re-enable once the query path
# pools connections. See issue #946.
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"

exec ../lib/benchmark-common.sh

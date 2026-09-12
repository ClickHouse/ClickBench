#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
export BENCH_RESTARTABLE=no
# Single-process engine: each query forks a fresh full-machine process with no
# shared scheduler across connections, so the concurrent-QPS test only
# oversubscribes RAM rather than measuring throughput. Skip it by default;
# override BENCH_CONCURRENT_DURATION to re-enable. See issue #946.
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"
# Turso has queries it simply cannot finish: Q5 (COUNT(DISTINCT UserID))
# ran for ~7h on c6a.4xlarge on 2026-07-21 and was still going when the
# global timeout killed the run at query 5 of 43, throwing away the four
# results it did have. 600s is ~1.7x the slowest query that has actually
# completed here (Q3, 353s cold), so it doesn't cut off anything turso can
# really do, and it bounds the hopeless ones at 600s each instead of
# unbounded. See timeout-seconds for the matching global budget.
export BENCH_QUERY_TIMEOUT="${BENCH_QUERY_TIMEOUT:-600}"
exec ../lib/benchmark-common.sh

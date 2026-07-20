#!/bin/bash
# clickbench (the vortex driver) handles its own dataset download/conversion.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_RESTARTABLE=no
# Single-process engine: each query forks a fresh full-machine process with no
# shared scheduler across connections, so the concurrent-QPS test only
# oversubscribes RAM rather than measuring throughput. Skip it by default;
# override BENCH_CONCURRENT_DURATION to re-enable. See issue #946.
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"
exec ../lib/benchmark-common.sh

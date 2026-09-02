#!/bin/bash
#
# GenDB's pipeline produces one specialized C++ binary per query (the .cpp
# files we ship in generated/ were synthesized by a multi-agent LLM pipeline
# running against the ClickBench schema + queries). At benchmark time we
# only have to compile them and run them against the pre-built per-column
# binary storage in db/.
#
# Restartable=no / Durable=yes: the binaries are embedded CLIs (no daemon
# to start/stop); the data on disk in db/ is persistent across cold cycles.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE=no
# Single-process engine: each query forks a fresh full-machine process with no
# shared scheduler across connections, so the concurrent-QPS test only
# oversubscribes RAM rather than measuring throughput. Skip it by default;
# override BENCH_CONCURRENT_DURATION to re-enable. See issue #946.
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"
exec ../lib/benchmark-common.sh

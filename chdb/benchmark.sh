#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
# ./start runs one long-lived Python process with a single chDB instance
# (server.py); ./query and the concurrent-QPS workers connect to it, each
# connection with its own session. Restarting it gives a cold run, and the
# QPS test measures the throughput of the shared instance.
export BENCH_CONCURRENT_WORKER=./concurrent-worker
exec ../lib/benchmark-common.sh

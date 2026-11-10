#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
# Long-lived query server (server.py). Restartable: the driver stops it, drops
# caches and starts it again before every query, so try 1 is a cold process;
# tries 2-3 hit the same process. Durable: the data is Parquet on disk, nothing
# lives in process memory, so ./load is not re-run.
export BENCH_RESTARTABLE=yes
export BENCH_DURABLE=yes
exec ../lib/benchmark-common.sh

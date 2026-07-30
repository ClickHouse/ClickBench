#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"

# infino runs as a persistent server (./start opens the table once and holds it
# warm; ./query is a client). Restart it before each query's cold try so try 1
# is cold and tries 2/3 hit the warm server — the same treatment the driver
# gives ClickHouse and other daemons.
export BENCH_RESTARTABLE=yes

# Data is durable on local disk; a restart reopens ./data, no reload.
export BENCH_DURABLE=yes

# The server answers one query at a time, so the concurrent-QPS test would only
# oversubscribe it. Skip by default.
export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"

# Disk cache lives beside the data so warm tries read cached column chunks.
export INFINO_CACHE_DIR="${INFINO_CACHE_DIR:-./cache}"

# Superfile segment size: many mid-size segments let the scan parallelise
# across all cores. 256 MB fits a 16-core box on up.
export INFINO_TARGET_SF_MB="${INFINO_TARGET_SF_MB:-256}"

# Disk-cache budget sized to the machine so the whole dataset stays resident
# (the 10 GiB default range-reads a >10 GiB dataset). ~75% of RAM: portable
# across machines, overridable. Memory sizing, not per-query tuning.
if [ -z "${INFINO_CACHE_BUDGET:-}" ] && [ -r /proc/meminfo ]; then
  ram_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  export INFINO_CACHE_BUDGET=$(( ram_kb * 1024 * 3 / 4 ))
fi

exec ../lib/benchmark-common.sh

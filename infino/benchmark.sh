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


# infino tuning (cache dir + budget). Shared with the raw load/start scripts so
# the playground gets the same config.
. "$(dirname "$0")/config.sh"

exec ../lib/benchmark-common.sh

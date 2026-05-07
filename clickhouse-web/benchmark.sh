#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# Data is read from a remote ClickHouse-hosted web disk; no local download.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh

#!/bin/bash
# Data is read from a remote ClickHouse-hosted web disk; no local download.
export BENCH_DOWNLOAD_SCRIPT=""
exec ../lib/benchmark-common.sh

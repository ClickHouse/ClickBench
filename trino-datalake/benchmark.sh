#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# Datalake variant: Parquet is read directly from public S3, no download.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_DURABLE=yes
# Trino bootstrap on a cold sysdisk pushes past the 300s default.
export BENCH_CHECK_TIMEOUT=3600
exec ../lib/benchmark-common.sh

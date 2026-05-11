#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# Datalake variant: Parquet is read directly from public S3, no download.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_DURABLE=yes
exec ../lib/benchmark-common.sh

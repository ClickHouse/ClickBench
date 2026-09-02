#!/bin/bash
# Datalake variant: Parquet is read directly from public S3, no download.
export BENCH_DOWNLOAD_SCRIPT=""
exec ../lib/benchmark-common.sh

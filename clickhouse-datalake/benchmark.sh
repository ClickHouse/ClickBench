#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# Data is read directly from S3, no local download.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_DURABLE=yes
exec ../lib/benchmark-common.sh

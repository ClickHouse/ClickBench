#!/bin/bash
# Data is read directly from S3, no local download.
export BENCH_DOWNLOAD_SCRIPT=""
exec ../lib/benchmark-common.sh

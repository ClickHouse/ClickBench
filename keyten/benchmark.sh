#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT=download-hits-parquet-single
export BENCH_RESTARTABLE=yes
export BENCH_DURABLE=yes
exec ../lib/benchmark-common.sh

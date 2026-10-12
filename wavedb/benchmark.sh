#!/bin/bash
# WaveDB on ClickBench: the shared driver (lib/benchmark-common.sh) runs install, start/check, the download,
# load, then every query cold (stop, drop caches, start, check) and twice hot. WaveDB is a daemon with its
# data on disk (BENCH_RESTARTABLE=yes, BENCH_DURABLE=yes: the defaults).
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
exec ../lib/benchmark-common.sh

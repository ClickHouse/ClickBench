#!/bin/bash
# CHYT executes against a remote YT cluster ($YT_PROXY); no local download.
export YT_USE_HOSTS=0
export CHYT_ALIAS="${CHYT_ALIAS:-*ch_public}"
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

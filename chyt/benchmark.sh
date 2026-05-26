#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# CHYT executes against a remote YT cluster ($YT_PROXY); no local download.
export YT_USE_HOSTS=0
export CHYT_ALIAS="${CHYT_ALIAS:-*ch_public}"
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_DURABLE=yes
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

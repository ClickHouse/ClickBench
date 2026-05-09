#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# query_bench (the vortex driver) handles its own dataset download/conversion.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# clickbench (the vortex driver) handles its own dataset download/conversion.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_DURABLE=yes
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"
# Druid degrades after some queries; the shared driver restarts between
# queries when restartable=yes (matches the original `pkill -f historical`
# hack now folded into stop).
export BENCH_DURABLE=yes
exec ../lib/benchmark-common.sh

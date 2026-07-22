#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"
# Druid degrades after some queries; the shared driver restarts between
# queries when restartable=yes (matches the original `pkill -f historical`
# hack now folded into stop).
exec ../lib/benchmark-common.sh

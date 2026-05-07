#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# YDB downloads CSV directly inside ./load (the ydb CLI imports from CSV).
export BENCH_DOWNLOAD_SCRIPT=""
# YDB has no benefit from server restart — it's a multi-node distributed
# cluster managed via ansible/systemd; stopping between queries is impractical.
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh

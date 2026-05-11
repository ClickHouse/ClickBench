#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# Data is loaded into a managed remote service provisioned by cloud-api.sh;
# the local runner only needs clickhouse-client.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_DURABLE=yes
export BENCH_MANAGED=yes
exec ../lib/benchmark-common.sh

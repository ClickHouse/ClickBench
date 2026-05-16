#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
#
# First-cold Impala start has to bootstrap the Hive metastore schema,
# wait for catalogd to register with statestored, and only then does
# impalad-1 publish /healthz=OK. On c6a.4xlarge this overruns the
# default 300s check window; 900s gives the four-container compose
# stack room without making real crashes wait forever before surfacing.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_DURABLE=yes
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh

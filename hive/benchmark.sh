#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
# Embedded Derby metastore lives in the container's writable layer;
# the cold-cycle docker rm + docker run in ./start wipes it. ./load
# is idempotent and reruns create.sql every cold cycle so the schema
# is present before the first try; the load wall-clock rolls into the
# cold-try timing per the standard BENCH_DURABLE=no contract.
export BENCH_DURABLE=no
exec ../lib/benchmark-common.sh

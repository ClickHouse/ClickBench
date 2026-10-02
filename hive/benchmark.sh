#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
# Embedded Derby metastore lives in the container's writable layer;
# the cold-cycle docker rm + docker run in ./start wipes it. ./load
# is idempotent and reruns create.sql every cold cycle so the schema
# is present before the first try; the load wall-clock rolls into the
# cold-try timing per the standard BENCH_DURABLE=no contract.
export BENCH_DURABLE=no
# The playground snapshots the guest post-load and every /query
# restores from that snapshot. If the pre-snapshot ./stop + ./start
# fires here, ./start's `docker rm -f hive; docker run …` wipes the
# same embedded Derby metastore that ./load just populated — the
# snapshot then captures a fresh container with an empty catalog,
# and every restored /query returns "Database clickbench does not
# exist". Skip the pre-snapshot restart so the running HS2 (with the
# loaded catalog) is what gets snapshotted.
export PLAYGROUND_SKIP_RESTART_BEFORE_SNAPSHOT=yes
exec ../lib/benchmark-common.sh

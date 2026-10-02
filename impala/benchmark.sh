#!/bin/bash
#
# First-cold Impala start has to bootstrap the Hive metastore schema,
# wait for catalogd to register with statestored, and only then does
# impalad-1 publish /healthz=OK. On c6a.4xlarge this overruns the
# default 300s check window; 900s gives the four-container compose
# stack room without making real crashes wait forever before surfacing.
#
# BENCH_RESTARTABLE=no skips the stop+start cycle between cold tries.
# Restarting catalogd wipes its in-memory catalog; with our
# -catalog_topic_mode=minimal + hms_event_polling_interval_s=0 setup
# (chosen to dodge the HMS notification-log issues at startup),
# catalogd doesn't proactively reload metadata from HMS, so
# `use clickbench` then fails with "Database does not exist" on every
# query. drop_caches alone gives a cold parquet read — the actual
# ClickBench bottleneck — without losing the catalog state that ./load
# put into the running cluster.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE=no
export BENCH_CHECK_TIMEOUT=900
# BENCH_RESTARTABLE=no covers the ClickBench cold-cycle driver, but the
# playground agent uses PLAYGROUND_SKIP_RESTART_BEFORE_SNAPSHOT for
# the equivalent gate. Without it, pre-snapshot ./stop + ./start runs
# `docker compose down` + `up`, which recreates catalogd with an empty
# in-memory catalog — snapshotted, then every restored /query fails
# with "Database does not exist: clickbench".
export PLAYGROUND_SKIP_RESTART_BEFORE_SNAPSHOT=yes
exec ../lib/benchmark-common.sh

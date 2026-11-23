#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"
# Pinot's quickstart starts a controller, broker, server and a Zookeeper
# inside one JVM and takes longer than the lib's 300 s default to be
# query-ready on a cold instance. 900 s clears the observed cold start.
export BENCH_CHECK_TIMEOUT=900
# Pinot QuickStart's -dataDir persistence is broken in 1.5.0/1.5.1: the
# second QuickStart invocation against an existing -dataDir always dies
# with IllegalStateException from Quickstart.java's
# Preconditions.checkState(quickstartRunnerDir.mkdirs()) — mkdirs() returns
# false because the directory from the first run already exists (verified
# by reproducing this locally in Docker and reading the Pinot source).
# A stop/start cycle therefore always wipes the in-memory table/segment
# registration and there is no supported way to bring the daemon back up
# against its previous state directory.
#
# What *does* survive the cycle is the segment tar files QuickStart wrote
# to a plain local directory (batch/hits/segments/, not process memory —
# verified locally: kill -9 the JVM, restart it, the .tar.gz files are
# still on disk). BENCH_DURABLE=no makes the shared driver re-run ./load
# after every restart; our ./load exploits this by re-pushing those
# existing tars straight to the controller's segment-upload API
# (https://docs.pinot.apache.org/build-with-pinot/ingestion/batch-ingestion/segment-upload)
# instead of re-parsing hits.tsv, so the "reload" on cold tries 2-129
# (43 queries x 3 tries) takes seconds instead of the ~78 min a real
# from-source reload would need. This keeps the real stop/start/
# drop_caches cycle other systems get, rather than skipping it via
# BENCH_RESTARTABLE=no.
export BENCH_DURABLE=no
# Skip the pre-snapshot ./stop+./start cycle: the loaded
# state lives only in the daemon's process memory (in-process
# DataFrame, JVM heap caches) and stopping wipes it. The
# playground agent reads this and snapshots the running daemon.
export PLAYGROUND_SKIP_RESTART_BEFORE_SNAPSHOT=yes
exec ../lib/benchmark-common.sh

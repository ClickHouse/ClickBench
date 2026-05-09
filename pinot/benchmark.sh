#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"
export BENCH_RESTARTABLE=yes
# Pinot's quickstart starts a controller, broker, server and a Zookeeper
# inside one JVM and takes longer than the lib's 300 s default to be
# query-ready on a cold instance. 900 s clears the observed cold start.
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh

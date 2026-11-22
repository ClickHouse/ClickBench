#!/bin/bash
# HoloDb as a service: the HoloDb.Server image runs in Docker with the store bind-mounted from ./holodb-data. Each query
# is one client round trip timed by the client tool; the server's Open happens in the untimed start.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh

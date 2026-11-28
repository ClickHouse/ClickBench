#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_DURABLE=no
# The `hits` view lives only in the server process; restarting it
# re-registers the view on the next /load.
export PLAYGROUND_SKIP_RESTART_BEFORE_SNAPSHOT=yes
exec ../lib/benchmark-common.sh

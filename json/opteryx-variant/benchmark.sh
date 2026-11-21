#!/bin/bash
# Opteryx is an in-process engine; it runs here as a long-lived query server
# (server.py, as in the main ClickBench ../../opteryx). Restartable: the driver
# stops it, drops the page cache and starts a fresh process before every
# query, so try 1 is cold and tries 2-3 run in the same process.
export BENCH_RESTARTABLE=yes
exec ../lib/benchmark-common.sh "$@"

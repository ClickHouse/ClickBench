#!/bin/bash
# NostromoDB is an embedded engine run as a command-line tool (in Docker): every
# statement is a fresh process, so there is no server to restart.
export BENCH_RESTARTABLE=no
exec ../lib/benchmark-common.sh "$@"

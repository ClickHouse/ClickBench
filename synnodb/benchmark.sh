#!/bin/bash
# SynnoDB is a DuckDB drop-in that routes the statements a pre-generated, workload-specific C++
# engine can answer to that engine, and everything else to DuckDB. See README.md.
#
# The data lives in a DuckDB file (durable); the engine keeps its own copy in memory and reloads
# it after every restart, on the first statement of the connection. The driver restarts the
# server before the first run of every query, so the cold run includes that reload.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
exec ../lib/benchmark-common.sh

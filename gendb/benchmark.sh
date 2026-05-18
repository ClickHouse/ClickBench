#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
#
# GenDB's pipeline produces one specialized C++ binary per query (the .cpp
# files we ship in generated/ were synthesized by a multi-agent LLM pipeline
# running against the ClickBench schema + queries). At benchmark time we
# only have to compile them and run them against the pre-built per-column
# binary storage in db/.
#
# Restartable=no / Durable=yes: the binaries are embedded CLIs (no daemon
# to start/stop); the data on disk in db/ is persistent across cold cycles.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE=no
export BENCH_DURABLE=yes
exec ../lib/benchmark-common.sh

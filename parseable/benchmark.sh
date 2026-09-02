#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-json"
chmod +x ../lib/download-hits-json
exec ../lib/benchmark-common.sh

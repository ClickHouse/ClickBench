#!/bin/bash
# The standard ClickBench driver over the step scripts in this directory; ./install fetches the dataset.
export BENCH_DOWNLOAD_SCRIPT=""
if [ ! -f ../lib/benchmark-common.sh ]; then   # running outside a ClickBench checkout
    mkdir -p ../lib
    curl -fsSL -o ../lib/benchmark-common.sh https://raw.githubusercontent.com/ClickHouse/ClickBench/main/lib/benchmark-common.sh
    chmod +x ../lib/benchmark-common.sh
fi
exec ../lib/benchmark-common.sh

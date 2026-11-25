#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"

# Full container restart between tries is too slow (bundles SSH, MySQL,
# Zookeeper, Hadoop, Hive, Kylin, Spark, Gluten). Not a durability
# issue: BENCH_DURABLE stays at its default "yes".
export BENCH_RESTARTABLE=no

# First boot of the full stack; 900s is generous headroom.
export BENCH_CHECK_TIMEOUT=900

exec ../lib/benchmark-common.sh

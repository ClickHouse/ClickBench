#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
# TileDB has no query language: the workload is expressed as Python, one
# expression per line in queries.sql, the same convention the other
# dataframe ports (pandas, dask, polars-dataframe, arcticdb) use. The
# default BENCH_QUERIES_FILE=queries.sql picks them up unchanged.
#
# The data is not held in process memory: it is a TileDB array on disk
# that survives a restart of the wrapper server, so BENCH_DURABLE keeps
# its default "yes" and each cold try is a genuine read from disk after
# drop_caches.
exec ../lib/benchmark-common.sh

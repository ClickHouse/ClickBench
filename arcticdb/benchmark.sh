#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
# ArcticDB has no query language of its own: the workload is expressed as
# Python, one expression per line in queries.sql, the same convention the
# other dataframe ports (pandas, dask, polars-dataframe) use. The default
# BENCH_QUERIES_FILE=queries.sql picks them up unchanged.
#
# Unlike those ports, the data is not held in process memory: it lives in
# an on-disk LMDB store that survives a restart of the wrapper server, so
# BENCH_DURABLE keeps its default "yes" and each cold try is a genuine
# read from disk after drop_caches.
exec ../lib/benchmark-common.sh

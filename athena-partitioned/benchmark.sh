#!/bin/bash
# Athena over the partitioned dataset (100 parquet files). Same scripts as
# ../athena (symlinked here); only the variant differs.
export ATHENA_VARIANT=partitioned
exec ../athena/benchmark.sh

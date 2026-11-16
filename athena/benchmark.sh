#!/bin/bash
# Athena entry for the shared ClickBench driver (../lib/benchmark-common.sh).
# ../athena-partitioned/benchmark.sh runs the same scripts with
# ATHENA_VARIANT=partitioned.
#
# Athena is serverless: the benchmark VM is only an AWS CLI client, and the
# table is an external table over the public parquet files on S3.
export ATHENA_VARIANT="${ATHENA_VARIANT:-single}"

# Nothing to download: Athena reads the dataset from S3.
export BENCH_DOWNLOAD_SCRIPT=""

# No local daemon, and nothing on the client to make cold. Athena has no
# cache we can drop, hence the "no-cold" tag.
export BENCH_RESTARTABLE=no

# The table definition lives in the Glue Data Catalog.
export BENCH_DURABLE=yes

# One boto3 client per concurrent-QPS worker, instead of forking ./query.
export BENCH_CONCURRENT_WORKER=./concurrent-worker

aws athena get-work-group --work-group "${ATHENA_WORKGROUP:-primary}" \
    --output text --query 'WorkGroup.Configuration.EngineVersion.EffectiveEngineVersion' \
    | sed 's/^/Athena engine version: /' || true

exec ../lib/benchmark-common.sh

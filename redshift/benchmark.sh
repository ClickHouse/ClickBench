#!/bin/bash
# Redshift entry for the shared ClickBench driver (../lib/benchmark-common.sh).
# The cluster must exist: run ./provision first (or use ./run-all.sh, which
# provisions, benchmarks, and deletes each configuration).
# ../redshift-serverless/benchmark.sh runs the same scripts with
# REDSHIFT_MODE=serverless.
export REDSHIFT_MODE="${REDSHIFT_MODE:-provisioned}"

# Nothing to download: COPY reads the dataset from S3.
export BENCH_DOWNLOAD_SCRIPT=""

# No local daemon; the cluster can't be made cold from here (tag "no-cold").
export BENCH_RESTARTABLE=no
export BENCH_DURABLE=yes

# One native connection per concurrent-QPS worker, instead of forking ./query.
export BENCH_CONCURRENT_WORKER=./concurrent-worker

(
    source ./env.sh
    if [ "$REDSHIFT_MODE" = provisioned ]; then
        echo "Redshift configuration: ${REDSHIFT_NODES}x ${REDSHIFT_NODE_TYPE}"
    else
        echo "Redshift configuration: serverless ${REDSHIFT_RPU} RPU"
    fi
    id=$(redshift_run "SELECT version()") &&
        aws redshift-data get-statement-result --id "$id" --output text \
            --query 'Records[0][0].stringValue' | sed 's/^/Redshift version: /'
) || true

exec ../lib/benchmark-common.sh

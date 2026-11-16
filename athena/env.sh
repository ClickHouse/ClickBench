#!/bin/bash
# Sourced by every Athena script. Works out the variant, region, database,
# data location and query-result location, so the scripts themselves take no
# arguments (the shared driver calls them bare).
#
# Env (all optional):
#   ATHENA_VARIANT    single (one 14 GB parquet file) | partitioned (100 files).
#                     ../athena-partitioned/benchmark.sh sets "partitioned".
#   AWS_REGION        region to run Athena in (default: the CLI's configured
#                     region, else us-east-1).
#   ATHENA_WORKGROUP  workgroup (default: primary).
#   ATHENA_OUTPUT     s3:// prefix for query results (default: a bucket
#                     clickbench-athena-<account>-<region>, created by ./install).

ATHENA_VARIANT="${ATHENA_VARIANT:-single}"
case "$ATHENA_VARIANT" in
    single)      ATHENA_PREFIX=hits_compatible/athena ;;
    partitioned) ATHENA_PREFIX=hits_compatible/athena_partitioned ;;
    *) echo "ATHENA_VARIANT must be 'single' or 'partitioned'" >&2; exit 2 ;;
esac

export AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

# The public dataset lives in eu-central-1 with a byte-for-byte mirror in
# us-east-1 (see ../lib/dataset-bucket.sh). Read the copy in Athena's region
# family so the scan does not cross the Atlantic.
case "$AWS_REGION" in
    eu-*) ATHENA_DATA_BUCKET=clickhouse-public-datasets ;;
    *)    ATHENA_DATA_BUCKET=clickhouse-public-datasets--us-east-1 ;;
esac
ATHENA_DATA_BUCKET="${CLICKBENCH_DATASET_BUCKET:-$ATHENA_DATA_BUCKET}"
ATHENA_LOCATION="s3://${ATHENA_DATA_BUCKET}/${ATHENA_PREFIX}/"

ATHENA_DATABASE="clickbench_${ATHENA_VARIANT}"
ATHENA_WORKGROUP="${ATHENA_WORKGROUP:-primary}"

# ./install resolves the default output location once and caches it here, so
# ./query does not pay for an STS call on every try.
if [ -z "${ATHENA_OUTPUT:-}" ] && [ -f .athena-output ]; then
    ATHENA_OUTPUT=$(cat .athena-output)
fi

export ATHENA_DATABASE ATHENA_WORKGROUP ATHENA_OUTPUT

# Run one statement and wait for it. Prints the query execution id on stdout.
# Returns non-zero (with the reason on stderr) unless it SUCCEEDED.
athena_run() {
    local sql="$1" id state reason
    id=$(aws athena start-query-execution \
        --work-group "$ATHENA_WORKGROUP" \
        --query-execution-context "Database=${ATHENA_DATABASE}" \
        --result-configuration "OutputLocation=${ATHENA_OUTPUT}" \
        --result-reuse-configuration 'ResultReuseByAgeConfiguration={Enabled=false}' \
        --query-string "$sql" \
        --output text --query QueryExecutionId) || return 1
    while :; do
        state=$(aws athena get-query-execution --query-execution-id "$id" \
            --output text --query QueryExecution.Status.State) || return 1
        case "$state" in
            SUCCEEDED) break ;;
            FAILED|CANCELLED)
                reason=$(aws athena get-query-execution --query-execution-id "$id" \
                    --output text --query QueryExecution.Status.StateChangeReason)
                echo "athena: query $id $state: $reason" >&2
                return 1 ;;
        esac
        sleep 0.2
    done
    echo "$id"
}

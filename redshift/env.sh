#!/bin/bash
# Sourced by every Redshift script. All SQL goes through the Redshift Data API
# (aws redshift-data), so no psql, password, or network access to the cluster
# is needed.
#
# Env:
#   REDSHIFT_MODE        provisioned (default) | serverless.
#                        ../redshift-serverless/benchmark.sh sets "serverless".
#   REDSHIFT_NODE_TYPE   provisioned node type (default ra3.xlplus).
#   REDSHIFT_NODES       provisioned number of nodes (default 4).
#   REDSHIFT_RPU         serverless base capacity in RPUs (default 128, the
#                        service default).
#   AWS_REGION           default: the CLI's configured region, else us-east-1.

REDSHIFT_MODE="${REDSHIFT_MODE:-provisioned}"
REDSHIFT_NODE_TYPE="${REDSHIFT_NODE_TYPE:-ra3.xlplus}"
REDSHIFT_NODES="${REDSHIFT_NODES:-4}"
REDSHIFT_RPU="${REDSHIFT_RPU:-128}"

export AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""
# The concurrent-QPS test runs many Data API calls in parallel; back off on
# throttling instead of failing the query.
export AWS_RETRY_MODE=adaptive
export AWS_MAX_ATTEMPTS=10

REDSHIFT_DATABASE=dev
REDSHIFT_ROLE=clickbench-redshift-s3

case "$REDSHIFT_MODE" in
    provisioned)
        REDSHIFT_CLUSTER="clickbench-${REDSHIFT_NODE_TYPE//./-}-${REDSHIFT_NODES}"
        REDSHIFT_NAME="$REDSHIFT_CLUSTER"
        REDSHIFT_TARGET=(--cluster-identifier "$REDSHIFT_CLUSTER" --db-user awsuser)
        ;;
    serverless)
        REDSHIFT_NAMESPACE="clickbench-${REDSHIFT_RPU}rpu"
        REDSHIFT_WORKGROUP="clickbench-${REDSHIFT_RPU}rpu"
        REDSHIFT_NAME="$REDSHIFT_WORKGROUP"
        # Data API as the namespace admin (a superuser), via its managed secret.
        REDSHIFT_TARGET=(--workgroup-name "$REDSHIFT_WORKGROUP")
        if [ -f ".redshift-conn-${REDSHIFT_NAME}" ]; then
            REDSHIFT_TARGET+=(--secret-arn "$(sed -n 5p ".redshift-conn-${REDSHIFT_NAME}")")
        fi
        ;;
    *) echo "REDSHIFT_MODE must be 'provisioned' or 'serverless'" >&2; exit 2 ;;
esac

# Native connection details (host, port, user, password, secret ARN), written
# by ./provision; readable only by the owner, and not committed.
REDSHIFT_CONN_FILE=".redshift-conn-${REDSHIFT_NAME}"

# Run SQL statements as one batch (one session, in order) and wait for it.
# Prints the statement id on stdout; sub-statement N is "<id>:N".
# Returns non-zero (with the error on stderr) unless it FINISHED.
redshift_run() {
    local id status
    if [ "$#" -eq 1 ]; then
        id=$(aws redshift-data execute-statement "${REDSHIFT_TARGET[@]}" \
            --database "$REDSHIFT_DATABASE" --sql "$1" --output text --query Id) || return 1
    else
        id=$(aws redshift-data batch-execute-statement "${REDSHIFT_TARGET[@]}" \
            --database "$REDSHIFT_DATABASE" --sqls "$@" --output text --query Id) || return 1
    fi
    while :; do
        status=$(aws redshift-data describe-statement --id "$id" --output text --query Status) || return 1
        case "$status" in
            FINISHED) break ;;
            FAILED|ABORTED)
                echo "redshift: statement $id $status: $(aws redshift-data describe-statement \
                    --id "$id" --output text --query Error)" >&2
                return 1 ;;
        esac
        sleep 0.5
    done
    echo "$id"
}

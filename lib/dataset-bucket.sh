#!/bin/bash
# Selects the copy of the public dataset bucket closest to this machine.
#
# The datasets live in clickhouse-public-datasets (eu-central-1). The paths
# ClickBench reads are mirrored byte-for-byte in
# clickhouse-public-datasets--us-east-1.
#
# Reading them across the Atlantic is ruinous for the entries that query S3 at
# query time. When the daily fleet moved from eu-central-1 to us-east-1 on
# 2026-07-20, clickhouse-web got ~30x slower on every machine size: the web
# disk issues many small range reads, so it is bound by round-trip latency
# rather than bandwidth. clickhouse-datalake, whose reads are large and
# sequential, lost a milder ~3.8x.
#
# Sourcing this file sets:
#   DATASET_BUCKET  bucket name, for s3:// URLs
#   DATASET_REGION  the bucket's region, for clients that need it stated
#   DATASET_HOST    virtual-hosted-style hostname, for https:// URLs
# and defines bench_dataset_sql, a stdin->stdout filter that rewrites
# references to the eu-central-1 bucket into the selected one.
#
# Selection: EU regions keep the original bucket, everything else takes the
# us-east-1 mirror. The machine's region comes from the EC2 instance metadata
# service; if that is unreachable (not EC2, or a different cloud) we keep the
# original bucket, which is what every non-EC2 run has always used. Set
# CLICKBENCH_DATASET_BUCKET=<name> to force a choice.

bench_detect_region() {
    local token
    token=$(curl -fsS --connect-timeout 1 --max-time 2 -X PUT \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
        'http://169.254.169.254/latest/api/token' 2>/dev/null) || return 1
    curl -fsS --connect-timeout 1 --max-time 2 \
        -H "X-aws-ec2-metadata-token: ${token}" \
        'http://169.254.169.254/latest/meta-data/placement/region' 2>/dev/null
}

if [ -n "${CLICKBENCH_DATASET_BUCKET:-}" ]; then
    DATASET_BUCKET="${CLICKBENCH_DATASET_BUCKET}"
else
    _bench_region=$(bench_detect_region) || _bench_region=''
    case "${_bench_region}" in
        # eu-west-* and friends are far closer to Frankfurt than us-east-1 is,
        # so the whole EU keeps the original bucket. An empty region means
        # detection failed.
        eu-*|'') DATASET_BUCKET='clickhouse-public-datasets' ;;
        *)       DATASET_BUCKET='clickhouse-public-datasets--us-east-1' ;;
    esac
    unset _bench_region
fi

case "${DATASET_BUCKET}" in
    *--us-east-1) DATASET_REGION='us-east-1' ;;
    *)            DATASET_REGION='eu-central-1' ;;
esac
DATASET_HOST="${DATASET_BUCKET}.s3.${DATASET_REGION}.amazonaws.com"

export DATASET_BUCKET DATASET_REGION DATASET_HOST

# Rewrites the three forms the create.sql files use: the virtual-hosted
# hostname with or without a region, the s3:// scheme, and the region a client
# is told to sign with (DuckDB's S3 secret). Leaving the original bucket
# selected makes every rule a no-op.
bench_dataset_sql() {
    sed -e "s|clickhouse-public-datasets\.s3\(\.[a-z0-9-]*\)\?\.amazonaws\.com|${DATASET_HOST}|g" \
        -e "s|s3://clickhouse-public-datasets/|s3://${DATASET_BUCKET}/|g" \
        -e "s|\(REGION '\)eu-central-1\('\)|\1${DATASET_REGION}\2|g"
}

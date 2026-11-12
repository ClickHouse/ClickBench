#!/bin/bash
# Launches one machine of the randomized benchmark: renders cloud-init.sh.in
# for a system of a group and calls ec2 run-instances. Called by launch.sh.
#
#   machine system group seed rows clickhouse_version parallel repeats
#   query_timeout payload_hash repo branch   (environment variables)
#   timeout   the time limit of the run on the machine, seconds (default 86400)
#   volume    the size of the root volume, GB (default 2000: the TSV of a
#             billion rows is about 750 GB, and the system stores its copy)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"

: "${machine:?}" "${system:?}" "${group:?}" "${seed:?}" "${rows:?}" "${clickhouse_version:?}"
: "${parallel:?}" "${repeats:?}" "${query_timeout:?}" "${payload_hash:?}"
repo="${repo:-ClickHouse/ClickBench}"
branch="${branch:-main}"
timeout="${timeout:-86400}"
volume="${volume:-2000}"
iops="${iops:-16000}"
throughput="${throughput:-1000}"

RETRY_RE='InsufficientInstanceCapacity|VcpuLimitExceeded|InstanceLimitExceeded|MaxSpotInstanceCountExceeded|RequestLimitExceeded|Throttling|VolumeLimitExceeded'
aws_retry() {
    local out rc
    while :; do
        out=$(AWS_PAGER='' "$@" 2>&1) && rc=0 || rc=$?
        if [ "${rc}" -eq 0 ]; then printf '%s\n' "${out}"; return 0; fi
        if printf '%s' "${out}" | grep -qE "${RETRY_RE}"; then
            printf 'aws: %s, retrying in 60s...\n' "$(printf '%s' "${out}" | grep -oE "${RETRY_RE}" | head -n1)" >&2
            sleep 60; continue
        fi
        printf '%s\n' "${out}" >&2; return "${rc}"
    done
}

arch=$(aws_retry aws ec2 describe-instance-types --instance-types "$machine" --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text)
ami=$(aws_retry aws ec2 describe-images --owners amazon --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04*" "Name=architecture,Values=${arch}" "Name=state,Values=available" --query 'sort_by(Images, &CreationDate) | [-1].[ImageId]' --output text)

rendered="$(mktemp)"
awk -v system="$system" -v group="$group" -v seed="$seed" -v rows="$rows" -v version="$clickhouse_version" \
    -v parallel="$parallel" -v repeats="$repeats" -v qt="$query_timeout" -v hash="$payload_hash" \
    -v repo="$repo" -v branch="$branch" -v t="$timeout" '
{
    gsub(/@system@/, system); gsub(/@group@/, group); gsub(/@seed@/, seed); gsub(/@rows@/, rows)
    gsub(/@clickhouse_version@/, version); gsub(/@parallel@/, parallel); gsub(/@repeats@/, repeats)
    gsub(/@query_timeout@/, qt); gsub(/@payload_hash@/, hash)
    gsub(/@repo@/, repo); gsub(/@branch@/, branch); gsub(/@timeout@/, t)
    print
}' cloud-init.sh.in | gzip -9 > "${rendered}"

aws_retry aws ec2 run-instances --image-id "$ami" --instance-type "$machine" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true,VolumeSize=${volume},VolumeType=gp3,Iops=${iops},Throughput=${throughput}}" \
    --instance-initiated-shutdown-behavior terminate \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=clickbench-random-${system}}]" \
    --user-data "fileb://${rendered}" --query 'Instances[0].InstanceId' --output text
rm -f "${rendered}"

#!/bin/bash -x

# Launch a fresh VM that runs the hardware benchmark (hardware.sh) unattended
# and sends the result to the sink (see cloud-init.sh.in), then self-terminates.
#
#   ./run-benchmark.sh <instance type>
#   volume=1000 ./run-benchmark.sh m7i.48xlarge
#
# Results are collected from the sink by collect-new-results.sh.

set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"

machine="${1:?usage: run-benchmark.sh <instance type>}"
repo="${repo:=ClickHouse/ClickBench}"
branch="${branch:=main}"
timeout="${timeout:-10800}"
# The root volume. It holds the data only on machines without local SSDs.
# gp3 maxes at 16000 IOPS and 1000 MB/s per volume.
volume="${volume:-500}"           # GB
iops="${iops:-16000}"
throughput="${throughput:-1000}"  # MB/s

# Transient AWS errors that clear on their own: the vCPU quota frees as other
# benchmarks finish, API throttling clears within seconds. Others (bad AMI,
# missing IAM permissions, an instance type unknown in the region) fail fast.
#
# A lack of capacity for the instance type (InsufficientInstanceCapacity) is
# retried only for capacity_wait seconds: the large sizes of new families can
# stay unavailable for hours, and the workflow launches the machines one after
# another, so waiting for one would leave all the following ones unlaunched.
capacity_wait="${capacity_wait:-600}"
RETRY_RE='InsufficientInstanceCapacity|VcpuLimitExceeded|InstanceLimitExceeded|MaxSpotInstanceCountExceeded|RequestLimitExceeded|Throttling|VolumeLimitExceeded'
aws_retry() {
    local out rc reason start=${SECONDS}
    while :; do
        out=$(AWS_PAGER='' "$@" 2>&1) && rc=0 || rc=$?
        if [ "${rc}" -eq 0 ]; then printf '%s\n' "${out}"; return 0; fi
        reason=$(printf '%s' "${out}" | grep -oE "${RETRY_RE}" | head -n1)
        if [ "${reason}" = "InsufficientInstanceCapacity" ] && [ $(( SECONDS - start )) -ge "${capacity_wait}" ]; then
            printf 'aws: no capacity for %s for %ss, giving up\n' "${machine}" "${capacity_wait}" >&2
            return "${rc}"
        fi
        if [ -n "${reason}" ]; then
            printf 'aws: %s for %s, retrying in 60s...\n' "${reason}" "${machine}" >&2
            sleep 60; continue
        fi
        printf '%s\n' "${out}" >&2; return "${rc}"
    done
}

arch=$(aws_retry aws ec2 describe-instance-types --instance-types "$machine" --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text)
ami=$(aws_retry aws ec2 describe-images --owners amazon --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04*" "Name=architecture,Values=${arch}" "Name=state,Values=available" --query 'sort_by(Images, &CreationDate) | [-1].[ImageId]' --output text)

awk -v repo="$repo" -v branch="$branch" -v t="$timeout" \
    -v volume="$volume" -v iops="$iops" -v throughput="$throughput" '
{
    gsub(/@repo@/, repo); gsub(/@branch@/, branch); gsub(/@timeout@/, t)
    gsub(/@volume@/, volume); gsub(/@iops@/, iops); gsub(/@throughput@/, throughput)
    print
}' cloud-init.sh.in > "cloud-init.${machine}.sh"

aws_retry aws ec2 run-instances --image-id "$ami" --instance-type "$machine" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true,VolumeSize=${volume},VolumeType=gp3,Iops=${iops},Throughput=${throughput}}" \
    --instance-initiated-shutdown-behavior terminate \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=clickbench-hardware-${machine}}]" \
    --user-data "file://cloud-init.${machine}.sh"

#!/bin/bash -x

# Launch a fresh VM that runs the JSONBench benchmark of ONE system on ONE
# dataset size unattended, sends the result to the sink (see cloud-init.sh.in)
# and self-terminates.
#
#   ./run-benchmark.sh <system> <size>
#   machine=m6i.8xlarge ./run-benchmark.sh clickhouse 100
#
# <system> is a directory of json/, <size> is 1, 10, 100 or 1000 (millions of
# documents). The results are collected from the sink by collect-new-results.sh.

set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"

system="${1:?usage: run-benchmark.sh <system> <size>}"
size="${2:?usage: run-benchmark.sh <system> <size>}"
system="${system#json/}"
[ -x "${system}/benchmark.sh" ] || { echo "no such system: ${system}" >&2; exit 1; }
case "${size}" in 1|10|100|1000) ;; *) echo "size must be 1, 10, 100 or 1000" >&2; exit 1 ;; esac

# The machine of the original JSONBench results.
machine="${machine:-m6i.8xlarge}"
repo="${repo:-ClickHouse/ClickBench}"
branch="${branch:-main}"
clickbench_pr="${clickbench_pr:-}"

# The time limit for benchmark.sh. Loading a billion documents takes a day for
# the slowest systems, and some of their queries run for hours.
if [ -z "${timeout:-}" ]; then
    case "${size}" in
        1)    timeout=7200 ;;
        10)   timeout=14400 ;;
        100)  timeout=86400 ;;
        1000) timeout=259200 ;;
    esac
fi

# The same root volume for every size, so that all results are on the same
# storage: it fits the uncompressed 1000m dataset (~480 GB) twice over, plus
# the largest databases (~660 GB). gp3 maxes at 16000 IOPS and 1000 MB/s.
volume="${volume:-2000}"           # GB
iops="${iops:-16000}"
throughput="${throughput:-1000}"   # MB/s

# Transient AWS errors that clear on their own, see ../versions/run-benchmark.sh.
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

rendered="cloud-init.${system}.${size}.sh"
awk -v sys="$system" -v size="$size" -v repo="$repo" -v branch="$branch" -v t="$timeout" -v pr="$clickbench_pr" \
    -v volume="$volume" -v iops="$iops" -v throughput="$throughput" '
{
    gsub(/@system@/, sys); gsub(/@size@/, size)
    gsub(/@repo@/, repo); gsub(/@branch@/, branch)
    gsub(/@timeout@/, t); gsub(/@clickbench_pr@/, pr)
    gsub(/@volume@/, volume); gsub(/@iops@/, iops); gsub(/@throughput@/, throughput)
    print
}' cloud-init.sh.in > "${rendered}"

aws_retry aws ec2 run-instances --image-id "$ami" --instance-type "$machine" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true,VolumeSize=${volume},VolumeType=gp3,Iops=${iops},Throughput=${throughput}}" \
    --instance-initiated-shutdown-behavior terminate \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=jsonbench-${system}-${size}m}]" \
    --user-data "file://${rendered}"

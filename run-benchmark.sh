#!/bin/bash -x

machine="${1:-c6a.4xlarge}"
system="${2:-clickhouse}"
repo="${3:-ClickHouse/ClickBench}"
branch="${4:-main}"

arch=$(aws ec2 describe-instance-types --instance-types $machine --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text)
ami=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04*" "Name=architecture,Values=${arch}" "Name=state,Values=available" --query 'sort_by(Images, &CreationDate) | [-1].[ImageId]' --output text)

# Global per-system benchmark timeout — substituted at render time.
# Default keeps the 10h cap that worked for the slowest OLTP systems.
timeout="${timeout:-36000}"

awk -v sys="$system" -v repo="$repo" -v branch="$branch" -v t="$timeout" '
{
    gsub(/@system@/, sys)
    gsub(/@repo@/, repo)
    gsub(/@branch@/, branch)
    gsub(/@timeout@/, t)
    print
}' cloud-init.sh.in > cloud-init.sh

# Retry on InsufficientInstanceCapacity. AWS returns this when the AZ
# has no spare instances of the requested type — common for the larger
# Graviton/AMD metal sizes during peak hours. Real config errors (bad
# AMI id, missing IAM perms, malformed user-data, ...) still fail
# immediately; only capacity errors get the retry.
while :; do
    out=$(AWS_PAGER='' aws ec2 run-instances --image-id $ami --instance-type $machine \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true,VolumeSize=500,VolumeType=gp2}' \
        --instance-initiated-shutdown-behavior terminate \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=clickbench-${system}}]" \
        --user-data file://cloud-init.sh 2>&1) && rc=0 || rc=$?

    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$out"
        break
    fi

    if printf '%s' "$out" | grep -q 'InsufficientInstanceCapacity'; then
        printf 'run-instances: %s capacity unavailable, retrying in 60s...\n' "$machine" >&2
        sleep 60
        continue
    fi

    # Different error — don't loop on it.
    printf '%s\n' "$out" >&2
    exit "$rc"
done

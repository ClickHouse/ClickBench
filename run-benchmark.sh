#!/bin/bash -x

machine=${machine:=c6a.4xlarge}
system=${system:=clickhouse}
clickbench_pr=${clickbench_pr:=}

# When launched for a pull request and no explicit repo/branch are given,
# benchmark the PR's own head repository and branch. GH_TOKEN is optional:
# unauthenticated GitHub API calls are rate-limited per IP, which bites on
# the shared IPs of GitHub-hosted runners.
if [ -n "$clickbench_pr" ] && { [ -z "$repo" ] || [ -z "$branch" ]; }; then
    auth=()
    [ -n "$GH_TOKEN" ] && auth=(-H "Authorization: Bearer $GH_TOKEN")
    pr_head=$(curl -sSf "${auth[@]}" "https://api.github.com/repos/ClickHouse/ClickBench/pulls/${clickbench_pr}")
    repo=${repo:-$(jq -r '.head.repo.full_name' <<< "$pr_head")}
    branch=${branch:-$(jq -r '.head.ref' <<< "$pr_head")}
    if [ -z "$repo" ] || [ "$repo" = "null" ] || [ -z "$branch" ] || [ "$branch" = "null" ]; then
        echo "Cannot resolve the head repository and branch of PR #${clickbench_pr}" >&2
        exit 1
    fi
fi

repo=${repo:=ClickHouse/ClickBench}
branch=${branch:=main}

arch=$(aws ec2 describe-instance-types --instance-types $machine --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text)
ami=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04*" "Name=architecture,Values=${arch}" "Name=state,Values=available" --query 'sort_by(Images, &CreationDate) | [-1].[ImageId]' --output text)

# Global per-system benchmark timeout — substituted at render time.
# Default keeps the 10h cap that worked for the slowest OLTP systems.
timeout="${timeout:-36000}"

awk -v sys="$system" -v repo="$repo" -v branch="$branch" -v t="$timeout" -v pr="$clickbench_pr" '
{
    gsub(/@system@/, sys)
    gsub(/@repo@/, repo)
    gsub(/@branch@/, branch)
    gsub(/@timeout@/, t)
    gsub(/@clickbench_pr@/, pr)
    print
}' cloud-init.sh.in > cloud-init.sh

# Retry on transient capacity / quota errors:
#   InsufficientInstanceCapacity — AZ has no spare of the requested type;
#                                  common for bigger Graviton/AMD metal
#                                  sizes during peak hours.
#   VcpuLimitExceeded            — on-demand vCPU service quota hit
#                                  (per-region cap, frees as other
#                                  benchmarks finish).
#   InstanceLimitExceeded        — older AWS error code for the same.
#   MaxSpotInstanceCountExceeded — spot quota hit.
#
# All four resolve on their own once existing instances drain, so a
# 60 s polling loop is the right shape. Real config errors (bad AMI id,
# missing IAM perms, malformed user-data, ...) still fail immediately
# so a fundamentally broken invocation doesn't loop forever.
RETRY_RE='InsufficientInstanceCapacity|VcpuLimitExceeded|InstanceLimitExceeded|MaxSpotInstanceCountExceeded'
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

    reason=$(printf '%s' "$out" | grep -oE "$RETRY_RE" | head -n1)
    if [ -n "$reason" ]; then
        printf 'run-instances: %s for %s, retrying in 60s...\n' "$reason" "$machine" >&2
        sleep 60
        continue
    fi

    # Different error — don't loop on it.
    printf '%s\n' "$out" >&2
    exit "$rc"
done

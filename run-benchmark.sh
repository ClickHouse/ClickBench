#!/bin/bash -x

machine="${1:-c6a.4xlarge}"
system="${2:-clickhouse}"
repo="${3:-ClickHouse/ClickBench}"
branch="${4:-main}"

arch=$(aws ec2 describe-instance-types --instance-types $machine --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text)
ami=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04*" "Name=architecture,Values=${arch}" "Name=state,Values=available" --query 'sort_by(Images, &CreationDate) | [-1].[ImageId]' --output text)

# Forward selected runtime env vars (e.g. YT_PROXY, YT_TOKEN, CHYT_ALIAS
# needed by chyt's check/load/query) into the cloud-init script. Anything
# unset on the operator side is simply omitted.
runtime_env=""
for v in YT_PROXY YT_TOKEN CHYT_ALIAS; do
    val="${!v-}"
    if [ -n "$val" ]; then
        runtime_env+="export ${v}=$(printf %q "$val")"$'\n'
    fi
done

awk -v sys="$system" -v repo="$repo" -v branch="$branch" -v env="$runtime_env" '
{
    gsub(/@system@/, sys)
    gsub(/@repo@/, repo)
    gsub(/@branch@/, branch)
    gsub(/@runtime_env@/, env)
    print
}' cloud-init.sh.in > cloud-init.sh

AWS_PAGER='' aws ec2 run-instances --image-id $ami --instance-type $machine \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true,VolumeSize=500,VolumeType=gp2}' \
  --instance-initiated-shutdown-behavior terminate \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=clickbench-${system}}]" \
  --user-data file://cloud-init.sh

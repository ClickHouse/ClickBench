#!/bin/bash -x

machine="${1:-c6a.4xlarge}"
system="${2:-clickhouse}"
repo="${3:-ClickHouse/ClickBench}"
branch="${4:-main}"

arch=$(aws ec2 describe-instance-types --instance-types $machine --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text)
ami=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04*" "Name=architecture,Values=${arch}" "Name=state,Values=available" --query 'sort_by(Images, &CreationDate) | [-1].[ImageId]' --output text)

sed "s^@system@^${system}^; s^@repo@^${repo}^; s^@branch@^${branch}^;" < cloud-init.sh.in > cloud-init.sh

AWS_PAGER='' aws ec2 run-instances --image-id $ami --instance-type $machine \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true,VolumeSize=500,VolumeType=gp2}' \
  --instance-initiated-shutdown-behavior terminate \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=clickbench-${system}}]" \
  --user-data file://cloud-init.sh

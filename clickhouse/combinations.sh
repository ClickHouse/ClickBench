#!/bin/bash

# A helper script to run all ClickHouse self-hosted benchmarks in an unattended fashion:

pushd "$(dirname "${BASH_SOURCE[0]}")/.."
for BENCHMARK in clickhouse clickhouse-datalake clickhouse-parquet clickhouse-web
do
    pushd "${BENCHMARK}"
    for MACHINE in c6a.metal c6a.4xlarge
    do
        aws ec2 run-instances --count 1 --image-id ami-0d1ddd83282187d18 --instance-type "${MACHINE}" --block-device-mappings 'DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true,VolumeSize=500,VolumeType=gp2}' --key-name milovidov --security-group-ids sg-013790293e9640422 --instance-initiated-shutdown-behavior terminate --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=clickbench}]' --user-data file://cloud-init.sh
    done
    popd
done
popd

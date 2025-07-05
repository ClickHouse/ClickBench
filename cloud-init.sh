#!/bin/bash -x

# This is the script for cloud-init, to run on a VM in unattended fashion. Example:
<<///
sed 's/pg_duckdb-indexed/clickhouse/' < cloud-init.sh.in > cloud-init.sh
aws ec2 run-instances --count 1 --image-id ami-0d1ddd83282187d18 --instance-type c6a.4xlarge \
 --block-device-mappings 'DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true,VolumeSize=500,VolumeType=gp2}' \
 --key-name milovidov --security-group-ids sg-013790293e9640422 --instance-initiated-shutdown-behavior terminate \
 --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=clickbench}]' \
 --user-data file://cloud-init.sh
///

apt-get update
apt-get install -y wget curl git

git clone --depth 1 https://github.com/ClickHouse/ClickBench.git
cd ClickBench/pg_duckdb-indexed
echo -n 'Disk usage before: ' >> log
df -B1 / | tail -n1 | awk '{ print $3 }' >> log
./benchmark.sh 2>&1 | tee -a log
echo -n 'Disk usage after: ' >> log
df -B1 / | tail -n1 | awk '{ print $3 }' >> log
echo 'System: pg_duckdb-indexed' >> log
echo -n 'Machine: ' >> log
curl 'http://169.254.169.254/latest/meta-data/instance-type' >> log

# Save the results.
# Prepare the database as follows:
<<///
CREATE DATABASE sink;

CREATE TABLE sink.data
(
    time DateTime MATERIALIZED now(),
    content String,
    CONSTRAINT length CHECK length(content) < 1024 * 1024
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/sink/data/{shard}', '{replica}') PRIMARY KEY ();

CREATE USER sink IDENTIFIED WITH no_password
DEFAULT DATABASE sink
SETTINGS
    async_insert = 1 READONLY,
    max_query_size = '10M' READONLY;

CREATE QUOTA sink
KEYED BY ip_address
FOR RANDOMIZED INTERVAL 1 MINUTE MAX query_inserts = 10, written_bytes = 10000000,
FOR RANDOMIZED INTERVAL 1 HOUR MAX query_inserts = 50, written_bytes = 50000000,
FOR RANDOMIZED INTERVAL 1 DAY MAX query_inserts = 500, written_bytes = 200000000
TO sink;

GRANT INSERT ON sink.data TO sink;
///

RESULTS_URL="https://play.clickhouse.com/?user=sink&query=INSERT+INTO+data+FORMAT+RawBLOB"

curl ${RESULTS_URL} --data-binary @log
curl ${RESULTS_URL} --data-binary @/var/log/cloud-init-output.log

shutdown now

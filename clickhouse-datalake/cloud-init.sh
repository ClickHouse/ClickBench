#!/bin/bash

# See the docs in clickhouse/cloud-init.sh

BASE_URL='https://raw.githubusercontent.com/ClickHouse/ClickBench/main/clickhouse-datalake/'

apt-get update
apt-get install -y curl

wget $BASE_URL/{run.sh,create.sql,queries.sql}
chmod +x *.sh

curl https://clickhouse.com/ | sh

echo "Partitioned:" > log
./run.sh >> log

sed -i 's!athena_partitioned/hits_{0..99}.parquet!hits.parquet!' create.sql

echo "Single:" >> log
./run.sh >> log

echo $BASE_URL >> log
curl 'http://169.254.169.254/latest/meta-data/instance-type' >> log

RESULTS_URL="https://play.clickhouse.com/?user=sink&query=INSERT+INTO+data+FORMAT+RawBLOB"

curl ${RESULTS_URL} --data-binary @log

shutdown now

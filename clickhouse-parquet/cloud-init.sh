#!/bin/bash

# See the docs in clickhouse/cloud-init.sh

BASE_URL='https://raw.githubusercontent.com/ClickHouse/ClickBench/main/clickhouse-parquet/'

apt-get update
apt-get install -y wget curl

wget $BASE_URL/{run.sh,create.sql,queries.sql}
chmod +x *.sh

curl https://clickhouse.com/ | sh

seq 0 99 | xargs -P100 -I{} bash -c 'wget --no-verbose --continue https://clickhouse-public-datasets.s3.amazonaws.com/hits_compatible/athena_partitioned/hits_{}.parquet'

echo "Partitioned:" > log
./run.sh >> log

wget --no-verbose --continue 'https://clickhouse-public-datasets.s3.amazonaws.com/hits_compatible/hits.parquet'

sed -i 's/hits_\*\.parquet/hits.parquet/' create.sql

echo "Single:" >> log
./run.sh >> log

echo $BASE_URL >> log
curl 'http://169.254.169.254/latest/meta-data/instance-type' >> log

RESULTS_URL="https://play.clickhouse.com/?user=sink&query=INSERT+INTO+data+FORMAT+RawBLOB"

curl ${RESULTS_URL} --data-binary @log

shutdown now

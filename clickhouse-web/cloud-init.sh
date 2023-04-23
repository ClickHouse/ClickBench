#!/bin/bash

# See the docs in clickhouse/cloud-init.sh

BASE_URL='https://raw.githubusercontent.com/ClickHouse/ClickBench/main/clickhouse-web/'

apt-get update
apt-get install -y wget curl

wget $BASE_URL/{benchmark.sh,run.sh,create.sql,queries.sql}
chmod +x *.sh

./benchmark.sh > log

echo $BASE_URL >> log
curl 'http://169.254.169.254/latest/meta-data/instance-type' >> log

RESULTS_URL="https://play.clickhouse.com/?user=sink&query=INSERT+INTO+data+FORMAT+RawBLOB"

curl ${RESULTS_URL} --data-binary @log

shutdown now

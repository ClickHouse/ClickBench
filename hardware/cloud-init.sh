#!/bin/bash

# See the docs in clickhouse/cloud-init.sh

BASE_URL='https://raw.githubusercontent.com/ClickHouse/ClickBench/main/hardware/'

apt-get update
apt-get install -y curl

wget $BASE_URL/hardware.sh
chmod +x *.sh

./hardware.sh >> log

echo $BASE_URL >> log
curl 'http://169.254.169.254/latest/meta-data/instance-type' >> log

RESULTS_URL="https://play.clickhouse.com/?user=sink&query=INSERT+INTO+data+FORMAT+RawBLOB"

curl ${RESULTS_URL} --data-binary @log

shutdown now

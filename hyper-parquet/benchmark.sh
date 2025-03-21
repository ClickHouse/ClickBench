#!/bin/bash

sudo apt-get update
sudo apt-get install -y python3-pip
pip install --break-system-packages tableauhyperapi

seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

./run.sh | tee log.txt

cat log.txt | awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

#!/bin/bash

# Install

sudo apt-get update
sudo apt-get install -y python3-pip
pip install --break-system-packages psutil
pip install --break-system-packages chdb==2.2.0b1

# Load the data
seq 0 99 | xargs -P100 -I{} bash -c 'wget --no-verbose --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Run the queries

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -P '^\d|Killed|Segmentation' | sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

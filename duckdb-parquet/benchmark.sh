#!/bin/bash

# Install

# FIXME: uncomment
# sudo apt-get update
# sudo apt-get install -y python3-pip
# pip install duckdb psutil

# Load the data
# FIXME: uncomment
# seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

./load.py

# Run the queries

./run.sh 2>&1 | tee log.txt

wc -c my-db.duckdb

cat log.txt | grep -P '^\d|Killed|Segmentation' | sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

#!/bin/bash

# Install test

sudo apt-get update
sudo apt-get install -y python3-pip
pip install chdb psutil

# Load the data
seq 0 99 | xargs -P100 -I{} bash -c 'wget --no-verbose --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Run the queries

./run.sh 2>&1 | tee log.txt

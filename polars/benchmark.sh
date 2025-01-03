#!/bin/bash

# Install

sudo apt-get update
sudo apt-get install -y python3-pip
pip install -U --break-system-packages polars

# Download the data
wget --no-verbose --continue https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet

# Run the queries

./run.sh 2>&1 | tee log.txt

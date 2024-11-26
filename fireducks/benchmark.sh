#!/bin/bash

# Install
sudo apt-get update
sudo apt-get install -y python3-pip
pip install --upgrade --break-system-packages fireducks

# Download the data
wget --no-verbose --continue https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet

# Run the queries
./run.sh 2>&1 | tee log.txt

#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip
pip install -U polars

# On small machines it can only work with swap
sudo fallocate -l 200G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Download the data
wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet

# Run the queries

./run.sh 2>&1 | tee log.txt

echo "Data size: $(du -bcs hits.parquet)"

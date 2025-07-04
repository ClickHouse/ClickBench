#!/bin/bash

# Install

sudo apt-get update
sudo apt-get install -y python3-pip
pip install pandas
pip install chdb

# Download the data
wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet

# Run the queries

./run.sh 2>&1 | tee log.txt

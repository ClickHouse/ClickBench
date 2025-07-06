#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip
python3 -m venv myenv
source myenv/bin/activate
pip install pandas
pip install chdb

# Download the data
wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet

# Run the queries

./run.sh 2>&1 | tee log.txt

echo "Load time: 0"
echo "Data size: $(du -bcs hits.parquet)"

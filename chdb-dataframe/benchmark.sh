#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv
python3 -m venv myenv
source myenv/bin/activate
pip install pandas pyarrow
pip install chdb

# On small machines it can only work with swap
sudo fallocate -l 200G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Download the data
wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet

# Run the queries

SWAP_BEFORE=$(free | awk '/Swap/{print $3}')
/usr/bin/time -f "Memory usage: %M KB" ./query.py 2>&1 | tee log.txt
SWAP_AFTER=$(free | awk '/Swap/{print $3}')

MEM=$(grep -F "Memory usage" log.txt | grep -o -P '\d+')
SWAP_DELTA=$((SWAP_AFTER - SWAP_BEFORE))
SWAP_DELTA=$((SWAP_DELTA > 0 ? SWAP_DELTA : 0))
echo "Data size: $(( (MEM + SWAP_DELTA) * 1024 ))"

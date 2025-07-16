#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv
python3 -m venv myenv
source myenv/bin/activate
pip install polars

# On small machines it can only work with swap
sudo fallocate -l 200G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Download the data
../lib/download-parquet.sh

# Run the queries

/usr/bin/time -f "Memory usage: %M KB" ./query.py 2>&1 | tee log.txt

echo -n "Data size: "
grep -F "Memory usage" log.txt | grep -o -P '\d+ KB' | sed 's/KB/*1024/' | bc -l

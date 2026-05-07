#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv
python3 -m venv myenv
source myenv/bin/activate
pip install polars

# Download the data
../download-hits-parquet-single

# Run the queries

./query.py 2>&1 | tee log.txt

echo "Data size: $(du -bcs hits.parquet)"

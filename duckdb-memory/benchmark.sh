#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv
python3 -m venv myenv
source myenv/bin/activate
pip install duckdb psutil

# Load the data
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Run the queries

/usr/bin/time -v ./query.py 2>&1 | tee log.txt

cat log.txt | grep -P '^\d|Killed|Segmentation' | grep -F "Load time: " | head -n1

cat log.txt | grep -P '^\d|Killed|Segmentation' | grep -v -F "Load time: " | sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo -n "Data size: "
grep -F 'Maximum resident set size' log.txt | grep -o -P '\d+$' | awk '{ print $1 * 1024 }'

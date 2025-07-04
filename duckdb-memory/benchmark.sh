#!/bin/bash

# Install

sudo apt-get update
sudo apt-get install -y python3-pip
pip install duckdb==1.1.3 psutil

# Load the data

sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
pigz -d -f hits.csv.gz

# Run the queries

./query.py | tee log.txt 2>&1

cat log.txt | grep -P '^\d|Killed|Segmentation' | sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

/usr/bin/time -v ./memory.py

#!/bin/bash

# Install
sudo apt-get update
sudo apt-get install -y python3-pip
pip install psutil
pip install chdb

# Load the data
sudo apt-get install -y axel pigz
axel --quiet --num-connections=32 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
pigz -d -f hits.csv.gz
./load.py

# Run the queries
./run.sh 2>&1 | tee log.txt

# Process the log.txt
cat log.txt | grep -P '^\d|Killed|Segmentation' | sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

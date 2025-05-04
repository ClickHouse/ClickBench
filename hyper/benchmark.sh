#!/bin/bash

sudo apt-get update
sudo apt-get install -y python3-pip
pip install --break-system-packages tableauhyperapi

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
gzip -d -f hits.csv.gz

./load.py

./run.sh | tee log.txt

cat log.txt | 
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

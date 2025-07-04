#!/bin/bash

sudo apt-get update
sudo apt-get install -y python3-pip
pip install tableauhyperapi

sudo apt-get install -y axel pigz
axel --quiet --num-connections=32 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
pigz -d -f hits.csv.gz

./load.py

./run.sh | tee log.txt

cat log.txt |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

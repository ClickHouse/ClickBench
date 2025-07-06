#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y python3-pip
python3 -m venv myenv
source myenv/bin/activate
pip install tableauhyperapi

sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
pigz -d -f hits.csv.gz

echo -n "Load time: "
command time -f '%e' ./load.py

./run.sh | tee log.txt

cat log.txt |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo -n "Data size: "
du -b hits.hyper

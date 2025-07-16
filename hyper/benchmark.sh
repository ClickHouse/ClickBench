#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv
python3 -m venv myenv
source myenv/bin/activate
pip install tableauhyperapi

../lib/download-csv.sh

echo -n "Load time: "
command time -f '%e' ./load.py

./run.sh | tee log.txt

cat log.txt |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo -n "Data size: "
du -b hits.hyper

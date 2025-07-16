#!/bin/bash

# Install
sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv
python3 -m venv myenv
source myenv/bin/activate
pip install psutil
pip install chdb

# Load the data
../lib/download-csv.sh

echo -n "Load time: "
command time -f '%e' ./load.py

# Run the queries
./run.sh 2>&1 | tee log.txt

# Process the log.txt
cat log.txt | grep -P '^\d|Killed|Segmentation' | sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo -n "Data size: "
du -bcs .clickbench | grep total

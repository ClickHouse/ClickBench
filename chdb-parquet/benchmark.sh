#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv
python3 -m venv myenv
source myenv/bin/activate
pip install psutil
pip install chdb

# Load the data
../lib/download-parquet-partitioned.sh

# Run the queries

./run.sh 2>&1 | tee log.txt

echo "Load time: 0"
echo "Data size: $(du -bcs hits*.parquet | grep total)"

cat log.txt | grep -P '^\d|Killed|Segmentation' | sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

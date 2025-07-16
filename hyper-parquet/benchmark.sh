#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv
python3 -m venv myenv
source myenv/bin/activate
pip install tableauhyperapi

../lib/download-parquet-partitioned.sh

./run.sh | tee log.txt
echo "Data size: $(du -bcs hits*.parquet | grep total)"
echo "Load time: 0"

cat log.txt | awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

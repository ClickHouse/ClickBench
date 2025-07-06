#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip
python3 -m venv myenv
source myenv/bin/activate
pip install duckdb psutil

# Go to the web ui and obtain a token
# https://motherduck.com/docs/key-tasks/authenticating-and-connecting-to-motherduck/authenticating-to-motherduck/
# Save the token as the motherduck_token environment variable:
# export motherduck_token=...

# Load the data

echo -n "Load time: "
command time -f '%e' ./load.py

# Run the queries

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -P '^\d|Killed|Segmentation' | sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

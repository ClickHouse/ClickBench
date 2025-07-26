#!/bin/bash

# ⚠️ Used as a base for spark-*/benchmark.sh — keep in sync where possible (check README-accelerators.md for the details).

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv openjdk-17-jdk

export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)/"
export PATH=$JAVA_HOME/bin:$PATH

python3 -m venv myenv
source myenv/bin/activate
pip install pyspark==4.0.0 psutil

# Load the data

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Run the queries

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -P '^Time:\s+([\d\.]+)|Failure!' | sed -r -e 's/Time: //; s/^Failure!$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo "Data size: $(du -b hits.parquet)"
echo "Load time: 0"

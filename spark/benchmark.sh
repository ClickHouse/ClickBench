#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip openjdk-17-jdk

export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64/"
export PATH=$JAVA_HOME/bin:$PATH

pip install pyspark==4.0.0 psutil

# Load the data

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Run the queries

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -P '^Time:\s+([\d\.]+)|Failure!' | sed -r -e 's/Time: //; s/^Failure!$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo "Data size: $(du -b hits.parquet)"
echo "Load time: 0"

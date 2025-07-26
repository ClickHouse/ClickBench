#!/bin/bash

# ⚠️ Derived from spark/benchmark.sh — keep in sync where possible (check README.md for the details).
# Current differences:
# - pyspark==3.5.6 version is used (latest stable for Comet 0.9.0)
# - Comet installation is added
# - auto-save results

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv openjdk-17-jdk

export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)/"
export PATH=$JAVA_HOME/bin:$PATH

python3 -m venv myenv
source myenv/bin/activate
pip install pyspark==3.5.6 psutil

# Load the data

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Install Comet

wget --continue --progress=dot:giga 'https://repo1.maven.org/maven2/org/apache/datafusion/comet-spark-spark3.5_2.12/0.9.0/comet-spark-spark3.5_2.12-0.9.0.jar' -O comet.jar

# Run the queries

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -P '^Time:\s+([\d\.]+)|Failure!' | sed -r -e 's/Time: //; s/^Failure!$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

# Save results

MACHINE="c6a.4xlarge"

mkdir -p results
./process_results.py "$MACHINE" > "results/${MACHINE}.json"

echo "Results have been saved to results/${MACHINE}.json"

echo "Data size: $(du -b hits.parquet)"
echo "Load time: 0"

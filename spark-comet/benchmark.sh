#!/bin/bash

# Note: Derived from spark/benchmark.sh — keep in sync where possible (check README.md for the details).
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

COMET_JAR_URL='https://repo1.maven.org/maven2/org/apache/datafusion/comet-spark-spark3.5_2.12/0.9.0/comet-spark-spark3.5_2.12-0.9.0.jar'

wget --continue --progress=dot:giga $COMET_JAR_URL -O comet.jar

# Run the queries

./run.sh 2>&1 | tee log.txt

# Print results to stdout as required
cat log.txt | grep -P '^Time:\s+([\d\.]+)|Failure!' | sed -r -e 's/Time: //; s/^Failure!$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

DATA_SIZE=$(du -b hits.parquet | cut -f1)

echo "Data size: $DATA_SIZE"
echo "Load time: 0"

# Save results as JSON

MACHINE="${1:-c6a.4xlarge}"  # Use first argument as machine name, default to c6a.4xlarge
COMET_VERSION=$(echo $COMET_JAR_URL | grep -Po ".{5}(?=.jar)")
SPARK_VERSION=$(pip freeze | grep '^pyspark==' | cut -d '=' -f3)

mkdir -p results

(
cat << EOF
{
    "system": "Spark (Comet)",
    "date": "$(date +%Y-%m-%d)",
    "machine": "${MACHINE}",
    "cluster_size": 1,
    "proprietary": "no",
    "tuned": "no",
    "comment": "Using Comet ${COMET_VERSION} with Spark ${SPARK_VERSION}",
    "tags": ["Java", "Rust", "column-oriented", "Spark derivative", "DataFusion", "Parquet"],
    "load_time": 0,
    "data_size": ${DATA_SIZE},
    "result": [
EOF

cat log.txt | grep -P '^Time:\s+([\d\.]+)|Failure!' | sed -r -e 's/Time: //; s/^Failure!$/null/' |
    awk -v total=$(grep -cP '^Time:\s+[\d\.]+|Failure!' log.txt) '
        { 
            if (i % 3 == 0) printf "\t\t[";
            printf $1;
            if (i % 3 != 2) printf ",";
            else {
                if (i < total - 1) printf "],\n";
                else printf "]";
            }
            i++;
        }'

cat << EOF

    ]
}
EOF
) > "results/${MACHINE}.json"

echo "Results have been saved to results/${MACHINE}.json"

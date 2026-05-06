#!/bin/bash

# Spark + Velox via Apache Gluten. Velox is a C++ vectorised execution
# engine, integrated into Spark through Gluten's Velox backend.
#
# Note: Keep in sync with spark-*/benchmark.sh (see README-accelerators.md for details)
#
# Pre-built Gluten jars are only published for x86_64. On ARM you need to
# build the jar from source (see https://gluten.apache.org/docs/getting-started/build-guide/).

GLUTEN_VERSION=1.4.0
SPARK_RELEASE=spark35

# Install

sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv openjdk-17-jdk

export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)/"
export PATH=$JAVA_HOME/bin:$PATH

python3 -m venv myenv
source myenv/bin/activate
pip install pyspark==3.5.2 psutil

# Load the data

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Install Gluten + Velox bundle

GLUTEN_TAR_URL="https://github.com/apache/incubator-gluten/releases/download/v${GLUTEN_VERSION}/apache-gluten-${GLUTEN_VERSION}-incubating-bin-${SPARK_RELEASE}.tar.gz"

wget --continue --progress=dot:giga "$GLUTEN_TAR_URL" -O gluten.tar.gz
tar -xzf gluten.tar.gz
mv "gluten-velox-bundle-spark3.5_2.12-linux_amd64-${GLUTEN_VERSION}.jar" gluten.jar

# Run the queries

./run.sh 2>&1 | tee log.txt

# Print results to stdout as required
cat log.txt | grep -P '^Time:\s+([\d\.]+)|Failure!' | sed -r -e 's/Time: //; s/^Failure!$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

DATA_SIZE=$(du -b hits.parquet | cut -f1)

echo "Data size: $DATA_SIZE"
echo "Load time: 0"

# Save results as JSON

MACHINE="${1:-c6a.4xlarge}"
SPARK_VERSION=$(pip freeze | grep '^pyspark==' | cut -d '=' -f3)

mkdir -p results

(
cat << EOF
{
    "system": "Spark (Velox)",
    "date": "$(date +%Y-%m-%d)",
    "machine": "${MACHINE}",
    "cluster_size": 1,
    "proprietary": "no",
    "tuned": "no",
    "comment": "Apache Gluten ${GLUTEN_VERSION} with Velox backend, Spark ${SPARK_VERSION}",
    "tags": ["Java", "C++", "column-oriented", "Spark derivative", "Velox", "Parquet"],
    "load_time": 0,
    "data_size": ${DATA_SIZE},
    "result": [
EOF

cat log.txt | grep -P '^Time:\s+([\d\.]+)|Failure!' | sed -r -e 's/Time: //; s/^Failure!$/null/' |
    awk -v total=$(grep -cP '^Time:\s+[\d\.]+|Failure!' log.txt) '
        {
            if (i % 3 == 0) printf "\t\t[";
                if ($1 == "null") printf "null";
                else printf "%.3f", $1;
            if (i % 3 != 2) printf ", ";
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

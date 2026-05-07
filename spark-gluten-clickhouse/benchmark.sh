#!/bin/bash

# Spark + Apache Gluten with the ClickHouse backend ('ch'). Unlike the
# Velox backend, no pre-built bundle is published for the CH backend, so
# this script builds both libch.so (a ClickHouse fork) and the Gluten
# Spark plugin from source.
#
# Note: Keep in sync with spark-*/benchmark.sh (see README-accelerators.md for details)
#
# The ClickHouse compile is RAM-hungry; building on c6a.4xlarge (32 GB)
# may OOM. A larger machine (>= 64 GB RAM, c6a.8xlarge or above) is
# recommended.

set -e

GLUTEN_VERSION=v1.4.0
SPARK_PROFILE=spark-3.5

# Install build prerequisites:
#  - Java 8 to build Gluten via Maven (Gluten's pom requires JDK 8)
#  - Java 17 to run Spark (auto-selected via JAVA_HOME below)
#  - Clang 18, cmake, ninja, etc. to build libch.so
sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv \
    openjdk-8-jdk-headless openjdk-17-jdk-headless \
    maven git cmake ccache ninja-build nasm yasm gawk \
    lsb-release wget software-properties-common gnupg

# Install Clang 18 (required by libch.so build).
wget -O - https://apt.llvm.org/llvm.sh | sudo bash -s -- 18

export CC=clang-18
export CXX=clang++-18

# pyspark venv
python3 -m venv myenv
source myenv/bin/activate
pip install pyspark==3.5.2 psutil

# Load the data
../download-hits-parquet-single

# Clone Gluten and the Kyligence ClickHouse fork that the CH backend wraps.
GLUTEN_DIR="$PWD/gluten"
if [ ! -d "$GLUTEN_DIR" ]; then
    git clone --depth 1 --branch "$GLUTEN_VERSION" \
        https://github.com/apache/gluten.git "$GLUTEN_DIR"
fi

CH_BRANCH=$(grep '^CH_BRANCH=' "$GLUTEN_DIR/cpp-ch/clickhouse.version" | cut -d= -f2)
CH_DIR="$GLUTEN_DIR/cpp-ch/ClickHouse"
if [ ! -d "$CH_DIR" ]; then
    git clone --recursive --shallow-submodules \
        --branch "$CH_BRANCH" \
        https://github.com/Kyligence/ClickHouse.git "$CH_DIR"
fi

# Build libch.so. The wrapper at cpp-ch/build_ch invokes the inner
# ClickHouse build, whose final artifact ends up at cpp-ch/build/.
LIBCH_SO="$GLUTEN_DIR/cpp-ch/build/utils/extern-local-engine/libch.so"
if [ ! -f "$LIBCH_SO" ]; then
    bash "$GLUTEN_DIR/ep/build-clickhouse/src/build_clickhouse.sh"
fi

# Build the Gluten Spark plugin against the CH backend. JDK 8 is required
# at compile time per Gluten's pom; Spark itself runs under JDK 17 below.
# pyspark wheels ship Scala 2.12 jars, so build with scala-2.12 to match.
JAVA_HOME_8="/usr/lib/jvm/java-8-openjdk-$(dpkg --print-architecture)"
(
    cd "$GLUTEN_DIR"
    JAVA_HOME="$JAVA_HOME_8" PATH="$JAVA_HOME_8/bin:$PATH" \
        mvn -B clean package \
            -Pbackends-clickhouse -P"$SPARK_PROFILE" -Pscala-2.12 \
            -DskipTests -Dcheckstyle.skip
)

# Symlink the produced uber jar (jar-with-dependencies) and libch.so into
# the entry directory; query.py expects them as ./gluten.jar and ./libch.so.
GLUTEN_JAR=$(ls "$GLUTEN_DIR"/backends-clickhouse/target/gluten-*-spark-3.5-jar-with-dependencies.jar 2>/dev/null | head -n1)
if [ -z "$GLUTEN_JAR" ]; then
    echo "ERROR: could not locate built Gluten CH-backend jar" >&2
    ls "$GLUTEN_DIR/backends-clickhouse/target/" >&2 || true
    exit 1
fi
ln -sf "$GLUTEN_JAR" gluten.jar
ln -sf "$LIBCH_SO" libch.so

# Run Spark queries under JDK 17.
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)/"
export PATH="$JAVA_HOME/bin:$PATH"

./run.sh 2>&1 | tee log.txt

# Print results to stdout as required
cat log.txt | grep -P '^Time:\s+([\d\.]+)|Failure!' | sed -r -e 's/Time: //; s/^Failure!$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

DATA_SIZE=$(du -b hits.parquet | cut -f1)

echo "Data size: $DATA_SIZE"
echo "Load time: 0"

# Save results as JSON
MACHINE="${1:-c6a.8xlarge}"
SPARK_VERSION=$(pip freeze | grep '^pyspark==' | cut -d '=' -f3)
GLUTEN_TAG="${GLUTEN_VERSION#v}"

mkdir -p results

(
cat << EOF
{
    "system": "Spark (Gluten-on-ClickHouse)",
    "date": "$(date +%Y-%m-%d)",
    "machine": "${MACHINE}",
    "cluster_size": 1,
    "proprietary": "no",
    "tuned": "no",
    "comment": "Apache Gluten ${GLUTEN_TAG} with the ClickHouse backend (libch.so), Spark ${SPARK_VERSION}",
    "tags": ["Java", "C++", "column-oriented", "Spark derivative", "ClickHouse", "Parquet"],
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

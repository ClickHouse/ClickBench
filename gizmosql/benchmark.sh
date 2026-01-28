#!/bin/bash

export HOME=/home/ubuntu

# Install requirements
sudo apt-get update -y
sudo apt install openjdk-17-jre-headless unzip netcat-openbsd -y

# Detect architecture (maps x86_64->amd64, aarch64->arm64)
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    ARCH="arm64"
fi

# Server setup Install
curl -L -o gizmosql.zip "https://github.com/gizmodata/gizmosql/releases/latest/download/gizmosql_cli_linux_${ARCH}.zip"
unzip gizmosql.zip
sudo mv gizmosql_server gizmosql_client /usr/local/bin/

# Install Java and the GizmoSQLLine CLI client
pushd /tmp
curl -L -o gizmosqlline https://github.com/gizmodata/gizmosqlline/releases/latest/download/gizmosqlline
chmod +x gizmosqlline
sudo mv gizmosqlline /usr/local/bin/
popd

# Source our env vars and utility functions for starting/stopping gizmosql server
. util.sh

# Start the GizmoSQL server in the background
start_gizmosql

# Create the table
gizmosqlline \
  -u ${GIZMOSQL_SERVER_URI} \
  -n ${GIZMOSQL_USERNAME} \
  -p ${GIZMOSQL_PASSWORD} \
  -f create.sql

# Load the data
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

echo -n "Load time: "
time gizmosqlline \
  -u ${GIZMOSQL_SERVER_URI} \
  -n ${GIZMOSQL_USERNAME} \
  -p ${GIZMOSQL_PASSWORD} \
  -f load.sql

stop_gizmosql

# Run the queries
#script --quiet --command="./run.sh" log.txt
./run.sh 2>&1 | tee log.txt

# Remove carriage returns from the log
sed -i 's/\r$//' log.txt

echo -n "Data size: "
wc -c clickbench.db

cat log.txt | \
  grep -E 'rows? selected \([0-9.]+ seconds\)|Killed|Segmentation' | \
  sed -E 's/.*rows? selected \(([0-9.]+) seconds\).*/\1/; s/.*(Killed|Segmentation).*/null/' | \
  awk '{
    if (NR % 3 == 1) printf "[";
    if ($1 == "null") printf "null";
    else printf $1;
    if (NR % 3 == 0) printf "],\n";
    else printf ", ";
  }'

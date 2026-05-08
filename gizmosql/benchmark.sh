#!/bin/bash

# needed by DuckDB
export HOME=/home/ubuntu

# Install requirements
sudo apt-get update -y
sudo apt-get install -y unzip netcat-openbsd

# Detect architecture (maps x86_64->amd64, aarch64->arm64)
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    ARCH="arm64"
fi

# Install the GizmoSQL server and client (gizmosql_client is the CLI shell) into a local directory
mkdir -p ./bin
curl -L -o gizmosql.zip "https://github.com/gizmodata/gizmosql/releases/latest/download/gizmosql_cli_linux_${ARCH}.zip"
unzip -o gizmosql.zip -d ./bin
chmod +x ./bin/gizmosql_server ./bin/gizmosql_client
export PATH="$PWD/bin:$PATH"

# Source our env vars and utility functions for starting/stopping gizmosql server
. util.sh

# Start the GizmoSQL server in the background
start_gizmosql

# Create the table
gizmosql_client --file create.sql

# Load the data
../download-hits-parquet-single

echo -n "Load time: "
time gizmosql_client --file load.sql

stop_gizmosql

# Run the queries
./run.sh 2>&1 | tee log.txt

# Remove carriage returns from the log
sed -i 's/\r$//' log.txt

echo -n "Data size: "
wc -c clickbench.db

cat log.txt | \
  grep -E 'Run Time: [0-9.]+s|Killed|Segmentation' | \
  sed -E 's/.*Run Time: ([0-9.]+)s.*/\1/; s/.*(Killed|Segmentation).*/null/' | \
  awk '{
    if (NR % 3 == 1) printf "[";
    if ($1 == "null") printf "null";
    else printf $1;
    if (NR % 3 == 0) printf "],\n";
    else printf ", ";
  }'

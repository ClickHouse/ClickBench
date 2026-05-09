#!/bin/bash

# needed by DuckDB
export HOME=/home/ubuntu

# Install requirements
sudo apt-get update -y
sudo apt-get install -y curl unzip netcat-openbsd

# Install the GizmoSQL server and client (gizmosql_client is the CLI shell)
# via the official one-line installer (https://install.gizmosql.com).
curl -fsSL https://install.gizmosql.com/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

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

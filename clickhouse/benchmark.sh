#!/bin/bash

# Install

if [ ! -x /usr/bin/clickhouse ]
then
    curl https://clickhouse.com/ | sh
    sudo ./clickhouse install --noninteractive
fi

# Optional: if you want to use higher compression:
if (( 0 )); then
    echo "
compression:
    case:
        method: zstd
    " | sudo tee /etc/clickhouse-server/config.d/compression.yaml
fi;

sudo clickhouse start

while true
do
    clickhouse-client --query "SELECT 1" && break
    sleep 1
done

# Determine which set of files to use depending on the type of run
if [ "$1" != "" ] && [ "$1" != "tuned" ] && [ "$1" != "tuned-memory" ]; then
    echo "Error: command line argument must be one of {'', 'tuned', 'tuned-memory'}"
    exit 1
else if [ ! -z "$1" ]; then
    SUFFIX="-$1"
fi
fi

# Load the data

clickhouse-client < create"$SUFFIX".sql

if [ ! -f hits.tsv ]
then
    wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
    gzip -d hits.tsv.gz
fi

clickhouse-client --time --query "INSERT INTO hits FORMAT TSV" < hits.tsv

# Run the queries

./run.sh "$1"

clickhouse-client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"

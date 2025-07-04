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
elif [ ! -z "$1" ]; then
    SUFFIX="-$1"
fi

# Load the data

clickhouse-client < create"$SUFFIX".sql

if [ ! -f hits.tsv ]
then
    sudo apt-get install -y axel pigz
    axel --num-connections=32 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
    pigz -d -f hits.tsv.gz
fi

echo -n "Load time: "
clickhouse-client --time --query "INSERT INTO hits FORMAT TSV" < hits.tsv

# Run the queries

./run.sh "$1"

echo -n "Data size: "
clickhouse-client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"

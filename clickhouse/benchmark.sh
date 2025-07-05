#!/bin/bash

# Install

if [ ! -x /usr/bin/clickhouse ]
then
    curl https://clickhouse.com/ | sh
    sudo ./clickhouse install --noninteractive
fi

# Optional: if you want to use higher compression:
if (( 1 )); then
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

seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'
sudo mv hits_*.parquet /var/lib/clickhouse/user_files/
sudo chown clickhouse:clickhouse /var/lib/clickhouse/user_files/hits_*.parquet

echo -n "Load time: "
clickhouse-client --time --query "INSERT INTO hits SELECT * FROM file('hits_*.parquet')" --max-insert-threads $(( $(nproc) / 4 ))

# Run the queries

./run.sh "$1"

echo -n "Data size: "
clickhouse-client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"

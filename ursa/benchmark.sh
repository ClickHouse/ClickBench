#!/bin/bash

# Install

wget --continue --progress=dot:giga "https://ursa-private-builds.s3.eu-central-1.amazonaws.com/ursa-0.0.1/ursa"
chmod +x ursa

./ursa server > server.log 2>&1 &

while true
do
    ./ursa client --query "SELECT 1" && break
    sleep 1
done

# Load the data

./ursa client < create.sql

seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'
sudo mv hits_*.parquet user_files/
sudo chown clickhouse:clickhouse user_files/hits_*.parquet

echo -n "Load time: "
./ursa client --time --query "INSERT INTO hits SELECT * FROM file('hits_*.parquet')" --max-insert-threads $(( $(nproc) / 4 ))

# Run the queries

./run.sh "$1"

echo -n "Data size: "
./ursa client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"

killall ursa

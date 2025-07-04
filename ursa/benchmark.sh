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

sudo apt-get install -y axel pigz
axel --quiet --num-connections=32 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -d -f hits.tsv.gz

./ursa client --time --query "INSERT INTO hits FORMAT TSV" < hits.tsv

# Run the queries

./run.sh "$1"

./ursa client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"

killall ursa

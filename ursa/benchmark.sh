#!/bin/bash

# Install

wget "https://ursa-private-builds.s3.eu-central-1.amazonaws.com/ursa-0.0.1/ursa"
chmod +x ursa

./ursa server &

while true
do
    ./ursa client --query "SELECT 1" && break
    sleep 1
done

# Load the data

./ursa client < create.sql

wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz

./ursa client --time --query "INSERT INTO hits FORMAT TSV" < hits.tsv

# Run the queries

./run.sh "$1"

./ursa client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"

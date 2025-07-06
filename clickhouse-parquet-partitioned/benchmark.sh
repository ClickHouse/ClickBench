#!/bin/bash

# Install

curl https://clickhouse.com/ | sh

seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Run the queries

./run.sh

echo "Load time: 0"
echo "Data size: $(du -bcs hits*.parquet | grep total)"

# Use for ClickHouse (Parquet, single)
# du -b hits.parquet

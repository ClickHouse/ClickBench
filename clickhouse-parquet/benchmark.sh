#!/bin/bash

# Install

curl https://clickhouse.com/ | sh

# Use for ClickHouse (Parquet, single)
# wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Use for ClickHouse (Parquet, partitioned)
seq 0 99 | xargs -P100 -I{} bash -c 'wget --no-verbose --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Run the queries

./run.sh

# Use for ClickHouse (Parquet, single)
# du -b hits.parquet

#!/bin/bash

# Install

curl https://clickhouse.com/ | sh

# Use for clickhouse-local (single)
# wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Use for clickhouse-local (partitioned)
seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Run the queries

./run.sh

# Use for clickhouse-local (single)
# du -b hits.parquet

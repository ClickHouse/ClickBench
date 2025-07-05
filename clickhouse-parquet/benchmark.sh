#!/bin/bash

# Install

curl https://clickhouse.com/ | sh

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Run the queries

./run.sh

# Use for ClickHouse (Parquet, single)
# du -b hits.parquet

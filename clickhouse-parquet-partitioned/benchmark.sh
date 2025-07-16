#!/bin/bash

# Install

curl https://clickhouse.com/ | sh

../lib/download-parquet-partitioned.sh

# Run the queries

./run.sh

echo "Load time: 0"
echo "Data size: $(du -bcs hits*.parquet | grep total)"

# Use for ClickHouse (Parquet, single)
# du -b hits.parquet

#!/bin/bash

# Install

curl https://clickhouse.com/ | sh

../lib/download-parquet.sh

# Run the queries

./run.sh

echo "Load time: 0"
echo "Data size: $(du -bcs hits.parquet)"

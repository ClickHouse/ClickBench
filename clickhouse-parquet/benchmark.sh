#!/bin/bash

# Install

curl https://clickhouse.com/ | sh

../download-hits-parquet-single

# Run the queries

./run.sh

echo "Load time: 0"
echo "Data size: $(du -bcs hits.parquet)"

#!/bin/bash

# Install

curl https://clickhouse.com/ | sh

# Configure

> clickhouse-local.yaml echo "
page_cache_size: auto
"

# Run the queries

./run.sh

echo "Load time: 0"
echo "Data size: 14737666736"

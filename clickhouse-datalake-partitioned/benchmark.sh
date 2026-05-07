#!/bin/bash

# Install

curl https://clickhouse.com/ | sh

# Configure

RAM=$(awk '/MemTotal/ {print int($2 * 0.8 * 1024)}' /proc/meminfo)
> clickhouse-local.yaml echo "
page_cache_max_size: ${RAM}
"

# Run the queries

./run.sh

echo "Load time: 0"
echo "Data size: 14737666736"

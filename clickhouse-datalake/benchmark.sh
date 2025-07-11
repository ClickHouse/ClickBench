#!/bin/bash

# Install

curl https://clickhouse.com/ | sh

# Configure

> clickhouse-local.yaml echo "
filesystem_caches:
    cache:
        path: '/dev/shm/clickhouse/'
        max_size_ratio_to_total_space: 0.9
"

# Run the queries

./run.sh

echo "Load time: 0"
echo "Data size: 14779976446"

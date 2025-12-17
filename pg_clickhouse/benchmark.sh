#!/bin/bash

# apt-get update -y
# env DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl sudo

# Install and start ClickHouse and Postgres
./clickhouse.sh "$@"
./postgres.sh

# Run the queries
./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
clickhouse-client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"

cat log.txt | grep -oP 'Time: \d+\.\d+ ms|psql: error' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/; s/^.*psql: error.*$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; if ($1 == "null") { printf $1 } else { printf $1 / 1000 }; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

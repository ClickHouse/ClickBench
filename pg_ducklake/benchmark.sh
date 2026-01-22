#!/bin/bash

set -e

sudo apt-get update -y
sudo apt-get install -y docker.io postgresql-client

wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet
sudo docker run -d --name pgduck -p 5432:5432 -e POSTGRES_PASSWORD=duckdb -v ./hits.parquet:/tmp/hits.parquet pgducklake/pgducklake:18-main -c duckdb.max_memory=10GB

sleep 5 # wait for pgducklake start up

echo -n "Load time: "
command time -f '%e' psql postgres://postgres:duckdb@localhost:5432/postgres -f create.sql 2>&1

./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
sudo docker exec -i pgduck du -bcs /var/lib/postgresql/ | grep total

cat log.txt | grep -oP 'Time: \d+\.\d+ ms|psql: error' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/; s/^.*psql: error.*$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; if ($1 == "null") { printf $1 } else { printf $1 / 1000 }; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

#!/bin/bash

set -ex

#sudo apt-get update
#sudo apt-get install -y docker.io
#sudo apt-get install -y postgresql-client

wget --continue https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet
sudo docker run -d --name pgduck -p 5432:5432 -e POSTGRES_PASSWORD=duckdb -v ./hits.parquet:/tmp/hits.parquet pgduckdb/pgduckdb:17-v0.3.1 -c duckdb.max_memory=10GB

sleep 5
psql postgres://postgres:duckdb@localhost:5432/postgres -f create.sql
./run.sh 2>&1 | tee log.txt

sudo docker exec -it pgduck du -bcs /var/lib/postgresql/data /tmp/hits.parquet

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

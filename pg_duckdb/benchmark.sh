#!/bin/bash

set -e

sudo apt-get update
sudo apt-get install -y docker.io
sudo apt-get install -y postgresql-client

sleep 10 # TODO wait loop
sudo docker run -d --name pgduck -p 5432:5432 -e POSTGRES_PASSWORD=duckdb pgduckdb/pgduckdb:16-main

psql postgres://postgres:duckdb@localhost:5432/postgres -f create.sql
./run.sh 2>&1 | tee log.txt

sudo docker exec -it pgduck du -bcs /var/lib/postgresql/data

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

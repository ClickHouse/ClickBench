#!/bin/bash

set -ex

#sudo apt-get update
#sudo apt-get install -y docker.io
#sudo apt-get install -y postgresql-client

wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz
sudo chmod 777 ./

sudo docker run -d --name pgduck -p 5432:5432 -e POSTGRES_PASSWORD=duckdb -v ./:/tmp/files pgduckdb/pgduckdb:16-main

sleep 5
docker exec -i pgduck psql -U postgres -c 'CREATE DATABASE test'
docker exec -i pgduck psql -U postgres -d test -c 'CREATE EXTENSION IF NOT EXISTS pg_duckdb'
docker exec -i pgduck psql -U postgres -d test -f /tmp/files/create.sql
time docker exec -i pgduck split /tmp/files/hits.tsv --verbose  -n r/$(( $(nproc)/2 )) --filter='psql -U postgres -d test -t -c "\\copy hits FROM STDIN"'
docker exec -i pgduck du -bcs /var/lib/postgresql/data

docker exec -i pgduck psql -U postgres -d test -c "ALTER DATABASE test SET duckdb.force_execution = true;"
./run.sh 2>&1 | tee log.txt

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

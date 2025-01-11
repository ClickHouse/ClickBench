#!/bin/bash


sudo apt-get update
sudo apt-get install -y docker.io
sudo apt-get install -y postgresql-client

wget --no-verbose --continue https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet
sudo docker run -d --name pg_mooncake -p 5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust - -v ./hits.parquet:/tmp/hits.parquet mooncakelabs/pg_mooncake

sleep 5
psql postgres://postgres:pg_mooncake@localhost:5432/postgres -f create.sql

# COPY 99997497
# Time: 576219.151 ms (09:36.219)

./run.sh 2>&1 | tee log.txt

sudo docker exec -it pg_mooncake du -bcs /var/lib/postgresql/data

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
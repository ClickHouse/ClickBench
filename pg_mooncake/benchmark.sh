#!/bin/bash


#install docker if needed.

sudo apt-get update -y
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker

sudo apt-get install -y postgresql-client

../lib/download-parquet.sh

docker run -d --name pg_mooncake -p 5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust -v ./hits.parquet:/tmp/hits.parquet mooncakelabs/pg_mooncake:17-v0.1.0

sleep 5
echo -n "Load time: "
command time -f '%e' psql postgres://postgres:pg_mooncake@localhost:5432/postgres -q -t -f create.sql

# COPY 99997497
# Time: 576219.151 ms (09:36.219)

./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
docker exec -i pg_mooncake du -bcs /var/lib/postgresql/data | grep total

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

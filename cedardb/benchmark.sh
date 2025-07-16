#!/bin/bash -e

# docker
sudo apt-get update -y
sudo apt-get install -y docker.io postgresql-client gzip

# download dataset
../lib/download-tsv.sh
mkdir data
mv hits.tsv data
chmod -R 777 data
rm -rf db
mkdir db

# get and configure CedarDB image
echo "Starting CedarDB..."
docker run --rm -p 5432:5432 -v ./data:/data -v ./db:/var/lib/cedardb/data -e CEDAR_PASSWORD=test --name cedardb cedardb/cedardb:latest > /dev/null 2>&1 &

# wait for container to start
until pg_isready -h localhost --dbname postgres -U postgres > /dev/null 2>&1; do sleep 1; done

# create table and ingest data
PGPASSWORD=test  psql -h localhost -U postgres -t < create.sql
echo "Inserting data..."
echo -n "Load time: "
PGPASSWORD=test command time -f '%e' psql -h localhost -U postgres -q -t -c "COPY hits FROM '/data/hits.tsv';"

# get ingested data size
echo -n "Data size: "
PGPASSWORD=test psql -h localhost -U postgres -q -t -c "SELECT pg_total_relation_size('hits');"

# run benchmark
echo "running benchmark..."
./run.sh 2>&1 | tee log.txt

cat log.txt | \
    grep -oP 'Time: \d+\.\d+ ms' | \
    sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' | \
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

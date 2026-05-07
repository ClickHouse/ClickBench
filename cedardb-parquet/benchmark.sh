#!/bin/bash -e

# docker
sudo apt-get update -y
sudo apt-get install -y docker.io postgresql-client

# download dataset
../download-hits-parquet-single data
chmod -R 777 data
rm -rf db
mkdir db

# get and configure CedarDB image
echo "Starting CedarDB..."
docker run --rm -p 5432:5432 -v ./data:/data -v ./db:/var/lib/cedardb/data -e CEDAR_PASSWORD=test --name cedardb cedardb/cedardb:latest > /dev/null 2>&1 &

# wait for container to start
until pg_isready -h localhost --dbname postgres -U postgres > /dev/null 2>&1; do sleep 1; done

# create view over the parquet file
PGPASSWORD=test psql -h localhost -U postgres -t < create.sql 2>&1 | tee load_out.txt
if grep 'ERROR' load_out.txt
then
    exit 1
fi

# data size = parquet file size; load time = 0 (no ingestion)
echo -n "Data size: "
stat -c%s data/hits.parquet
echo "Load time: 0"

# run benchmark
echo "running benchmark..."
./run.sh 2>&1 | tee log.txt

cat log.txt | \
    grep -oP 'Time: \d+\.\d+ ms|psql: error' | \
    sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/; s/^.*psql: error.*$/null/' | \
    awk '{ if (i % 3 == 0) { printf "[" }; if ($1 == "null") { printf $1 } else { printf $1 / 1000 }; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

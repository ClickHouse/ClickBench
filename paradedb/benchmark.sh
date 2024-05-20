#!/bin/bash

# Cleanup function to reset the environment
cleanup() {
    echo ""
    echo "Cleaning up..."
    if sudo docker ps -q --filter "name=paradedb" | grep -q .; then
        sudo docker kill paradedb
    fi
    sudo docker rm paradedb
    echo "Done, goodbye!"
}

# Register the cleanup function to run when the script exits
trap cleanup EXIT

sudo apt-get update
sudo apt-get install -y docker.io
sudo apt-get install -y postgresql-client

if [ ! -e hits.parquet ]; then
    echo ""
    echo "Downloading dataset..."
    wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'
else
    echo ""
    echo "Dataset already downloaded, skipping..."
fi

echo ""
echo "Pulling ParadeDB image..."
sudo docker run \
  --name paradedb \
  -e POSTGRESQL_USERNAME=myuser \
  -e POSTGRESQL_PASSWORD=mypassword \
  -e POSTGRESQL_DATABASE=mydb \
  -e POSTGRESQL_POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  -d \
  paradedb/paradedb:0.7.1

echo ""
echo "Waiting for ParadeDB to start..."
sleep 10

echo ""
echo "Loading dataset..."
export PGPASSWORD='postgres'
sudo docker cp hits.parquet paradedb:/tmp/
psql -h localhost -U postgres -d mydb -p 5432 -t < create.sql

# COPY 99997497
# Time: 1268695.244 ms (21:08.695)

echo ""
echo "Running queries..."
./run.sh 2>&1 | tee log.txt

sudo docker exec -it paradedb du -bcs /bitnami/lib/postgresql/data

# 15415061091     /var/lib/postgresql/data
# 15415061091     total

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

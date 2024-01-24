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

if [ ! -e hits.tsv ]; then
    echo ""
    echo "Downloading dataset..."
    wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
    gzip -d hits.tsv.gz
else
    echo ""
    echo "Dataset already downloaded, skipping..."
fi

echo ""
echo "Pulling ParadeDB image..."
sudo docker run \
    -e POSTGRES_USER=myuser \
    -e POSTGRES_PASSWORD=mypassword \
    -e POSTGRES_DB=mydb \
    -p 5432:5432 \
    --name paradedb \
    -d \
    paradedb/paradedb:0.5.1

echo ""
echo "Waiting for ParadeDB to start..."
sleep 10

echo ""
echo "Loading dataset..."
export PGPASSWORD='mypassword'
psql -h localhost -U myuser -d mydb -p 5432 -t < create.sql
psql -h localhost -U myuser -d mydb -p 5432 -t -c 'CALL paradedb.init();' -c '\timing' -c "\\copy hits FROM 'hits.tsv'"

# COPY 99997497
# Time: 1268695.244 ms (21:08.695)

echo ""
echo "Running queries..."
./run.sh 2>&1 | tee log.txt

sudo docker exec -it paradedb du -bcs /var/lib/postgresql/data

# 15415061091     /var/lib/postgresql/data
# 15415061091     total

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

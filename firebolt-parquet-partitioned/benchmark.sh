#!/bin/bash

# Download the partitioned hits parquet files
echo "Downloading dataset..."
rm -rf data
mkdir -p data
seq 0 99 | xargs -P100 -I{} bash -c 'wget -P data --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Start the container
sudo apt-get install -y docker.io jq
sudo docker run -dit --name firebolt-core --rm \
    --ulimit memlock=8589934592:8589934592 \
    --security-opt seccomp=unconfined \
    -p 127.0.0.1:3473:3473 \
    -v /firebolt-core/volume \
    -v ./data/:/firebolt-core/clickbench \
    ghcr.io/firebolt-db/firebolt-core:preview-rc

# Wait until Firebolt is ready
for _ in {1..600}
do
    curl -sS "http://localhost:3473/" --data-binary "SELECT 'Firebolt is ready';" > /dev/null && break
    sleep 1
done

# Create the database and external table
echo "Creating external table..."
curl -sS "http://localhost:3473/?enable_multi_query_requests=true" --data-binary "DROP DATABASE IF EXISTS clickbench;CREATE DATABASE clickbench;"
curl -sS "http://localhost:3473/?database=clickbench&enable_multi_query_requests=true" --data-binary @create.sql

# Print statistics
DATA_SIZE=$(du -bcs data/hits_*.parquet 2>/dev/null | grep total | awk '{print $1}')
if [ -z "$DATA_SIZE" ]; then
    DATA_SIZE=$(du -cs data/hits_*.parquet | grep total | awk '{print $1}')
fi
echo "Load time: 0"
echo "Data size: $DATA_SIZE"

# Run the benchmark
echo "Running the benchmark..."
./run.sh

# Stop the container and remove the data
sudo docker container stop firebolt-core
rm -rf data

#!/bin/bash

# Download the hits.parquet file
echo "Downloading dataset..."
rm -rf data
mkdir -p data
wget -P data --continue --progress=dot:giga "https://datasets.clickhouse.com/hits_compatible/hits.parquet"

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
    curl -s "http://localhost:3473/" --data-binary "SELECT 'Firebolt is ready';" > /dev/null && break
    sleep 1
done

# Create the database and external table
echo "Creating external table..."
curl -s "http://localhost:3473/?enable_multi_query_requests=true" --data-binary "DROP DATABASE IF EXISTS clickbench;CREATE DATABASE clickbench;"
curl -s "http://localhost:3473/?database=clickbench&enable_multi_query_requests=true" --data-binary @create.sql

# Print statistics
DATA_SIZE=$(stat -c%s data/hits.parquet 2>/dev/null || stat -f%z data/hits.parquet)
echo "Load time: 0"
echo "Data size: $DATA_SIZE"

# Run the benchmark
echo "Running the benchmark..."
./run.sh

# Stop the container and remove the data
sudo docker container stop firebolt-core
rm -rf data

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

# Ingest the data
echo "Ingesting the data..."
curl -s "http://localhost:3473/?enable_multi_query_requests=true" --data-binary "DROP DATABASE IF EXISTS clickbench;CREATE DATABASE clickbench;"
LOAD_TIME=$(curl -w "%{time_total}\n" -s "http://localhost:3473/?database=clickbench&enable_multi_query_requests=true" --data-binary @create.sql)

# Print statistics
COMPRESSED_SIZE=$(curl -s "http://localhost:3473/?database=clickbench&output_format=JSON_Compact" --data-binary "SELECT compressed_bytes FROM information_schema.tables WHERE table_name = 'hits';"  | jq '.data[0][0] | tonumber')
UNCOMPRESSED_SIZE=$(curl -s "http://localhost:3473/?database=clickbench&output_format=JSON_Compact" --data-binary "SELECT uncompressed_bytes FROM information_schema.tables WHERE table_name = 'hits';"  | jq '.data[0][0] | tonumber')
echo "Load time: $LOAD_TIME"
echo "Data size: $COMPRESSED_SIZE"
echo "Uncompressed data size: $UNCOMPRESSED_SIZE bytes"

if [ "$1" != "" ] && [ "$1" != "scan-cache" ]; then
    echo "Error: command line argument must be one of {'', 'scan-cache'}"
    exit 1
fi

# Run the benchmark
echo "Running the benchmark..."
./run.sh "$1"

# Stop the container and remove the data
sudo docker container stop firebolt-core
rm -rf data

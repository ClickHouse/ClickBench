#!/bin/bash

set -e

# Install Docker (Trino's official image bundles its own JRE).
sudo apt-get update -y
sudo apt-get install -y docker.io bc

# Download the dataset.
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Place the parquet file inside its own directory; the Hive connector
# reads every file in the table's external_location.
mkdir -p data/hits
ln -f hits.parquet data/hits/hits.parquet

# The Trino container runs as uid 1000 ("trino"), and writes the file
# metastore into this directory. Make sure that uid can write here even
# when benchmark.sh runs as root (cloud-init).
sudo chown -R 1000:1000 data

# Trino catalog configuration: Hive connector backed by a file metastore
# stored on the local filesystem, no Hadoop or external metastore required.
mkdir -p etc/catalog
cat > etc/catalog/hive.properties <<'EOF'
connector.name=hive
hive.metastore=file
hive.metastore.catalog.dir=local:///metastore
local.location=/clickbench
fs.native-local.enabled=true
hive.non-managed-table-writes-enabled=true
EOF

# Start the Trino server. The container exposes the data dir as
# /clickbench so it matches local.location above.
sudo docker rm -f trino 2>/dev/null || true
sudo docker run -d --name trino \
    -p 8080:8080 \
    -v "$PWD/etc/catalog/hive.properties:/etc/trino/catalog/hive.properties:ro" \
    -v "$PWD/data:/clickbench" \
    trinodb/trino:latest

# Wait for Trino to finish starting up.
until sudo docker logs trino 2>&1 | grep -q "SERVER STARTED"; do
    sleep 3
done
sleep 3

# Create the schema, the external table over the parquet file, and a view
# that exposes the ClickBench EventTime/EventDate column types.
LOAD_START=$(date +%s)
sudo docker cp create.sql trino:/tmp/create.sql
sudo docker exec -i trino trino --file /tmp/create.sql
LOAD_END=$(date +%s)

# Run the benchmark queries.
./run.sh 2>&1 | tee log.txt

echo "Load time: $((LOAD_END - LOAD_START))"
echo "Data size: $(stat -c %s hits.parquet)"

#!/bin/bash
set -e

# Install prerequisites
sudo apt-get update -y
sudo apt-get install -y wget curl jq bc docker.io
sudo systemctl start docker

# We use the Quickwit v0.9 release candidate. Stable v0.8.2 is missing
# `cardinality`, `wildcard`, and several other features the benchmark relies
# on; only the v0.9 line (still unreleased as of writing) provides them.
QW_IMAGE="quickwit/quickwit:v0.9.0-rc"
sudo docker pull "$QW_IMAGE"

# Quickwit's data directory (shared between the server and the local-ingest
# container).
QW_DATA="$(pwd)/qwdata"
sudo rm -rf "$QW_DATA"
mkdir -p "$QW_DATA"

# Start the server in the background. Quickwit defaults: REST on 7280, gRPC on 7281.
sudo docker run -d --name qw --network host -v "$QW_DATA":/quickwit/qwdata "$QW_IMAGE" run
echo "Quickwit container started"

# Wait for the server to come up.
for i in $(seq 1 60); do
    if curl -sS -f http://localhost:7280/api/v1/version >/dev/null 2>&1; then
        echo "Quickwit is ready"
        break
    fi
    sleep 1
done

# Create the index from the YAML config.
curl -sS -X POST http://localhost:7280/api/v1/indexes \
    -H 'Content-Type: application/yaml' \
    --data-binary @index_config.yaml

# Download the data
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.json.gz'

START=$(date +%s)

# Use `quickwit tool local-ingest` instead of the Elasticsearch-compatible
# bulk endpoint. v0.9's sharded ingest-v2 API caps single-node throughput
# to a few MB/s and gets stuck waiting for shards to scale, while
# `local-ingest` builds splits directly and writes them to the index
# storage. The running server picks up new splits on its next metastore
# poll (default 30s).
zcat hits.json.gz | sudo docker run --rm -i --network host \
    -v "$QW_DATA":/quickwit/qwdata \
    "$QW_IMAGE" tool local-ingest --index hits -y

# Wait long enough for the server to refresh its metastore view.
sleep 35

# Show stats.
curl -sS "http://localhost:7280/api/v1/indexes/hits/describe" | tee stats.json
echo

END=$(date +%s)
echo "Load time: $((END - START))"

# Data size on disk.
echo -n "Data size: "
sudo du -sb "$QW_DATA" | awk '{print $1}'

# Run queries
chmod +x run.sh
./run.sh

sudo docker stop qw 2>/dev/null || true
sudo docker rm qw 2>/dev/null || true

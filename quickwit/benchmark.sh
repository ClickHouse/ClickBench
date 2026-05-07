#!/bin/bash
set -e

# Install prerequisites
sudo apt-get update -y
sudo apt-get install -y wget curl jq bc python3 python3-requests

# Download Quickwit
QW_VERSION="0.8.2"
ARCH=$(uname -m)
QW_DIR="quickwit-v${QW_VERSION}"
wget --continue --progress=dot:giga \
    "https://github.com/quickwit-oss/quickwit/releases/download/v${QW_VERSION}/${QW_DIR}-${ARCH}-unknown-linux-gnu.tar.gz"
tar xzf "${QW_DIR}-${ARCH}-unknown-linux-gnu.tar.gz"

# Start the server in the background. Quickwit defaults: REST on 7280, gRPC on 7281.
pushd "$QW_DIR" >/dev/null
nohup ./quickwit run > ../quickwit.log 2>&1 &
QW_PID=$!
popd >/dev/null
echo "Quickwit started (PID $QW_PID)"

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

# Stream JSON directly into Quickwit via the Elasticsearch-compatible bulk API.
python3 load.py

# Force any in-flight commits and wait for the data to become searchable.
# The default commit timeout in index_config.yaml is 30s, so wait a bit longer.
sleep 60

# Show stats.
curl -sS "http://localhost:7280/api/v1/indexes/hits/describe" | tee stats.json
echo

END=$(date +%s)
echo "Load time: $((END - START))"

# Data size on disk (single-node uses qwdata/ inside the install dir).
echo -n "Data size: "
du -sb "$QW_DIR/qwdata" 2>/dev/null | awk '{print $1}'

# Run queries
chmod +x run.sh
./run.sh

# Stop Quickwit
kill "$QW_PID" 2>/dev/null || true

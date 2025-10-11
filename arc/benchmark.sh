#!/bin/bash
# Arc ClickBench Complete Benchmark Script
# This script installs Arc, loads data, and runs the benchmark

set -e

# Install system dependencies
echo "Installing system dependencies..."
sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv wget curl

# Create Python virtual environment
echo "Creating Python virtual environment..."
python3 -m venv arc-venv
source arc-venv/bin/activate

# Clone Arc repository if not exists
if [ ! -d "arc" ]; then
    echo "Cloning Arc repository..."
    git clone https://github.com/Basekick-Labs/arc.git
fi

cd arc

# Install Arc dependencies in venv
echo "Installing Arc dependencies..."
pip install --upgrade pip
pip install -r requirements.txt

# Create data directory
mkdir -p data logs

# Create API token for benchmark (using correct auth API)
echo "Creating API token..."
python3 << 'EOF'
from api.auth import AuthManager
import os

# Initialize auth manager
auth = AuthManager(db_path='./data/historian.db')

# Create token (no Permission import needed)
token = auth.create_token(
    name='clickbench',
    description='ClickBench benchmark access'
)

print(f"Created API token: {token}")

# Write token to file for run.sh to use
with open('../arc_token.txt', 'w') as f:
    f.write(token)
EOF

ARC_TOKEN=$(cat ../arc_token.txt)
echo "Token created successfully"

# Auto-detect CPU cores
if command -v nproc > /dev/null 2>&1; then
    CORES=$(nproc)
elif [ -f /proc/cpuinfo ]; then
    CORES=$(grep -c processor /proc/cpuinfo)
else
    CORES=4
fi

# Use 2x cores for balanced performance
WORKERS=$((CORES * 2))
echo "Starting Arc with $WORKERS workers ($CORES cores detected)..."

# Create minimal .env if not exists
if [ ! -f ".env" ]; then
    cat > .env << 'ENVEOF'
# Arc Configuration for ClickBench
STORAGE_BACKEND=local
LOCAL_STORAGE_PATH=./minio-data
PORT=8000
HOST=0.0.0.0
LOG_LEVEL=WARNING
QUERY_CACHE_ENABLED=false
BUFFER_MAX_SIZE=50000
BUFFER_MAX_AGE=5
ENVEOF
fi

# Start Arc server in background
gunicorn -w $WORKERS -b 0.0.0.0:8000 \
    -k uvicorn.workers.UvicornWorker \
    --timeout 300 \
    --access-logfile /dev/null \
    --error-logfile ../arc.log \
    --log-level warning \
    api.main:app > /dev/null 2>&1 &

ARC_PID=$!
echo "Arc started with PID: $ARC_PID"

# Wait for Arc to be ready (up to 30 seconds)
echo "Waiting for Arc to be ready..."
for i in {1..30}; do
    if curl -s -f http://localhost:8000/health > /dev/null 2>&1; then
        echo "✓ Arc is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "Error: Arc failed to start within 30 seconds"
        echo "Last 50 lines of logs:"
        tail -50 ../arc.log
        kill $ARC_PID 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

cd ..

# Download and prepare dataset
if [ ! -f "hits.parquet" ]; then
    echo "Downloading ClickBench dataset..."
    wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'
fi

echo "Dataset size:"
ls -lh hits.parquet

# Count rows using DuckDB
echo "Counting rows..."
python3 << 'EOF'
import duckdb
conn = duckdb.connect()
count = conn.execute("SELECT COUNT(*) FROM read_parquet('hits.parquet')").fetchone()[0]
print(f"Dataset contains {count:,} rows")
EOF

# Set environment variables for run.sh
export ARC_URL="http://localhost:8000"
export ARC_API_KEY="$ARC_TOKEN"
export PARQUET_FILE="$(pwd)/hits.parquet"

# Run benchmark
echo ""
echo "Running ClickBench queries via Arc HTTP API..."
echo "================================================"
./run.sh 2>&1 | tee log.txt

# Stop Arc
echo ""
echo "Stopping Arc..."
kill $ARC_PID 2>/dev/null || true
wait $ARC_PID 2>/dev/null || true

# Deactivate venv
deactivate

# Format results for ClickBench
echo ""
echo "Formatting results..."
cat log.txt | \
  grep -oP '^\d+\.\d+|^null' | \
  awk 'BEGIN {print "["}
       {
         if (NR % 3 == 1) printf "  [";
         printf "%s", $1;
         if (NR % 3 == 0) print "],";
         else printf ", ";
       }
       END {print "]"}' > results.json

echo ""
echo "✓ Benchmark complete!"
echo ""
echo "Results saved to: results.json"
echo "Logs saved to: log.txt"
echo ""
echo "To view results:"
echo "  cat results.json"

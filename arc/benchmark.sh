#!/bin/bash
# Arc ClickBench Complete Benchmark Script
# This script installs Arc, loads data, and runs the benchmark

set -e

# Install Python and dependencies
echo "Installing dependencies..."
pip3 install fastapi uvicorn duckdb pyarrow requests gunicorn

# Clone Arc repository
if [ ! -d "arc" ]; then
    echo "Cloning Arc repository..."
    git clone git@github.com:Basekick-Labs/arc.git
fi

cd arc

# Install Arc dependencies
echo "Installing Arc dependencies..."
pip3 install -r requirements.txt

# Start Arc in background
echo "Starting Arc server..."
ARC_API_KEY="clickbench-benchmark-key"
export ARC_API_KEY

# Create API token for benchmark
python3 << EOF
from api.auth import AuthManager, Permission
import os

auth = AuthManager(db_path='./data/arc.db')
token = auth.create_token(
    name='clickbench',
    permissions=Permission.FULL_ACCESS,
    description='ClickBench benchmark access'
)
print(f"Created API token: {token}")

# Write token to file for run.sh to use
with open('../arc_token.txt', 'w') as f:
    f.write(token)
EOF

ARC_TOKEN=$(cat ../arc_token.txt)

# Start Arc server
gunicorn -w 4 -b 0.0.0.0:8000 -k uvicorn.workers.UvicornWorker --timeout 300 api.main:app > ../arc.log 2>&1 &
ARC_PID=$!
echo "Arc started with PID: $ARC_PID"

# Wait for Arc to be ready
sleep 5
if ! curl -s -f http://localhost:8000/health > /dev/null; then
    echo "Error: Arc failed to start"
    cat ../arc.log
    exit 1
fi

echo "Arc is ready!"

cd ..

# Download and prepare dataset
if [ ! -f "hits.parquet" ]; then
    echo "Downloading ClickBench dataset..."
    wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'
fi

echo "Dataset size:"
ls -lh hits.parquet

# Count rows
echo "Counting rows..."
python3 << 'EOF'
import duckdb
conn = duckdb.connect()
count = conn.execute("SELECT COUNT(*) FROM read_parquet('hits.parquet')").fetchone()[0]
print(f"Dataset rows: {count:,}")
EOF

# Set environment variables for run.sh
export ARC_URL="http://localhost:8000"
export ARC_API_KEY="$ARC_TOKEN"

# Run benchmark
echo "Running ClickBench queries via Arc HTTP API..."
./run.sh 2>&1 | tee log.txt

# Stop Arc
echo "Stopping Arc..."
kill $ARC_PID 2>/dev/null || true

# Format results
echo "Formatting results..."
cat log.txt | \
  grep -E '^\d+\.\d+|null' | \
  awk 'BEGIN {print "["}
       {
         if (NR % 3 == 1) printf "  [";
         printf "%s", $1;
         if (NR % 3 == 0) print "],";
         else printf ", ";
       }
       END {print "]"}'

echo "Benchmark complete!"

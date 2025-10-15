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

# Create or reuse API token for benchmark
echo "Setting up API token..."
python3 << 'EOF'
from api.auth import AuthManager
import os
import time

# Initialize auth manager
auth = AuthManager(db_path='./data/arc.db')

# Try to create token, or reuse if exists
token = None
token_name = f'clickbench-{int(time.time())}'

try:
    # Try to create new token with timestamp
    token = auth.create_token(
        name=token_name,
        description='ClickBench benchmark access'
    )
    print(f"Created new API token: {token_name}")
except Exception as e:
    # If that fails, try with a simple name and catch if exists
    try:
        token = auth.create_token(
            name='clickbench',
            description='ClickBench benchmark access'
        )
        print(f"Created API token: clickbench")
    except ValueError:
        # Token already exists, list and use existing one
        print("Token 'clickbench' already exists, retrieving...")
        tokens = auth.list_tokens()
        for t in tokens:
            if t.get('name') == 'clickbench':
                token = t.get('token')
                print(f"Reusing existing token: clickbench")
                break

        if not token:
            raise Exception("Could not create or retrieve token")

# Write token to file for run.sh to use
with open('../arc_token.txt', 'w') as f:
    f.write(token)
EOF

ARC_TOKEN=$(cat ../arc_token.txt)
echo "Token ready: $ARC_TOKEN"

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
        echo "[OK] Arc is ready!"
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
DATASET_FILE="hits.parquet"
DATASET_URL="https://datasets.clickhouse.com/hits_compatible/hits.parquet"
EXPECTED_SIZE=14779976446  # 14GB

if [ -f "$DATASET_FILE" ]; then
    CURRENT_SIZE=$(stat -f%z "$DATASET_FILE" 2>/dev/null || stat -c%s "$DATASET_FILE" 2>/dev/null)
    if [ "$CURRENT_SIZE" -eq "$EXPECTED_SIZE" ]; then
        echo "[OK] Dataset already downloaded (14GB)"
    else
        echo "[WARNING] Dataset exists but size mismatch (expected: $EXPECTED_SIZE, got: $CURRENT_SIZE)"
        echo "Re-downloading dataset..."
        rm -f "$DATASET_FILE"
        wget --continue --progress=dot:giga "$DATASET_URL"
    fi
else
    echo "Downloading ClickBench dataset (14GB)..."
    wget --continue --progress=dot:giga "$DATASET_URL"
fi

FILE_SIZE=$(du -h "$DATASET_FILE" | cut -f1)
echo "Dataset size: $FILE_SIZE ($DATASET_FILE)"

# Count rows using DuckDB
echo "Counting rows..."
python3 << 'EOF'
import duckdb
conn = duckdb.connect()
count = conn.execute("SELECT COUNT(*) FROM read_parquet('hits.parquet')").fetchone()[0]
print(f"Dataset contains {count:,} rows")
EOF

# Set environment variables for benchmarking
export ARC_URL="http://localhost:8000"
export ARC_API_KEY="$ARC_TOKEN"
export DATABASE="clickbench"
export TABLE="hits"

# Load data into Arc by copying parquet file to storage
echo ""
echo "Loading ClickBench data into Arc..."
echo "================================================"

STORAGE_BASE="arc/data/arc"
TARGET_DIR="$STORAGE_BASE/$DATABASE/$TABLE"
TARGET_FILE="$TARGET_DIR/hits.parquet"

# Create target directory
mkdir -p "$TARGET_DIR"

# Check if already loaded
if [ -f "$TARGET_FILE" ]; then
    SOURCE_SIZE=$(stat -f%z "$DATASET_FILE" 2>/dev/null || stat -c%s "$DATASET_FILE" 2>/dev/null)
    TARGET_SIZE=$(stat -f%z "$TARGET_FILE" 2>/dev/null || stat -c%s "$TARGET_FILE" 2>/dev/null)

    if [ "$SOURCE_SIZE" -eq "$TARGET_SIZE" ]; then
        echo "[OK] Data already loaded (14GB)"
        echo "  Location: $TARGET_FILE"
    else
        echo "[WARNING] Existing file has different size, reloading..."
        rm -f "$TARGET_FILE"
        echo "  Copying parquet file to Arc storage..."
        cp "$DATASET_FILE" "$TARGET_FILE"
        echo "[OK] Data loaded successfully!"
    fi
else
    echo "  Copying parquet file to Arc storage..."
    echo "  Source: $DATASET_FILE"
    echo "  Target: $TARGET_FILE"
    cp "$DATASET_FILE" "$TARGET_FILE"
    echo "[OK] Data loaded successfully!"
    echo "  Table: $DATABASE.$TABLE"
    TARGET_SIZE=$(du -h "$TARGET_FILE" | cut -f1)
    echo "  Size: $TARGET_SIZE"
fi

echo ""
echo "Data loading complete."

# Verify query cache configuration
echo ""
echo "Verifying query cache configuration..."
cd arc
python3 << 'CACHECHECK'
import os
import sys

# Check all possible cache configuration sources
print("=" * 70)
print("Query Cache Configuration Check")
print("=" * 70)

# 1. Check arc.conf
cache_in_conf = None
try:
    from config_loader import get_config
    arc_config = get_config()
    cache_config = arc_config.config.get('query_cache', {})
    cache_in_conf = cache_config.get('enabled', None)
    print(f"  arc.conf:     enabled = {cache_in_conf}")
except Exception as e:
    print(f"  arc.conf:     Error reading: {e}")

# 2. Check .env file
cache_in_env = None
if os.path.exists('.env'):
    with open('.env', 'r') as f:
        for line in f:
            if line.strip().startswith('QUERY_CACHE_ENABLED'):
                cache_in_env = line.split('=')[1].strip().lower()
                print(f"  .env:         QUERY_CACHE_ENABLED = {cache_in_env}")
                break
    if cache_in_env is None:
        print(f"  .env:         QUERY_CACHE_ENABLED not set")
else:
    print(f"  .env:         File not found")

# 3. Check environment variable
cache_in_os_env = os.getenv("QUERY_CACHE_ENABLED")
if cache_in_os_env:
    print(f"  Environment:  QUERY_CACHE_ENABLED = {cache_in_os_env}")
else:
    print(f"  Environment:  QUERY_CACHE_ENABLED not set")

# 4. Check what init_query_cache will actually use
print("")
try:
    from api.query_cache import init_query_cache
    cache_instance = init_query_cache()
    if cache_instance is None:
        print(f"[OK] FINAL RESULT: Query cache is DISABLED")
    else:
        print(f"[ERROR] FINAL RESULT: Query cache is ENABLED")
        print(f"    TTL: {cache_instance.ttl_seconds}s")
        print(f"    Max size: {cache_instance.max_size}")
        print(f"\n  [WARNING] Cache must be disabled for valid benchmark results!")
except Exception as e:
    print(f"[ERROR] Error checking cache initialization: {e}")

print("=" * 70)
CACHECHECK

cd ..

# Test API token before running benchmark
echo ""
echo "Testing API token authentication..."
TEST_RESPONSE=$(curl -s -w "\n%{http_code}" -H "x-api-key: $ARC_API_KEY" "$ARC_URL/health")
HTTP_CODE=$(echo "$TEST_RESPONSE" | tail -n1)
if [ "$HTTP_CODE" = "200" ]; then
    echo "[OK] API token is valid"
else
    echo "[ERROR] API token test failed (HTTP $HTTP_CODE)"
    echo "Response: $(echo "$TEST_RESPONSE" | head -n-1)"
    echo ""
    echo "Debugging: Let's verify the token exists in the database..."
    cd arc
    python3 << 'DEBUGEOF'
from api.auth import AuthManager
auth = AuthManager(db_path='./data/arc.db')
tokens = auth.list_tokens()
print(f"Found {len(tokens)} tokens in database:")
for t in tokens:
    print(f"  - {t.get('name')}: {t.get('token')[:20]}...")
DEBUGEOF
    cd ..
    echo ""
    echo "Error: Cannot proceed without valid authentication"
    kill $ARC_PID 2>/dev/null || true
    exit 1
fi

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
echo "[OK] Benchmark complete!"
echo ""
echo "Results saved to: results.json"
echo "Logs saved to: log.txt"
echo ""
echo "Results (ClickBench JSON format):"
echo "=================================="
cat results.json

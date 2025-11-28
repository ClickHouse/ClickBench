#!/bin/bash
# Arc ClickBench Complete Benchmark Script (Go Binary Version)
set -e

# ============================================================
# 1. INSTALL ARC FROM .DEB PACKAGE
# ============================================================
echo "Installing Arc from .deb package..."
DEB_URL="https://github.com/basekick-labs/arc/releases/download/v25.12.1/arc_25.12.1_amd64.deb"
DEB_FILE="arc_25.12.1_amd64.deb"

if [ ! -f "$DEB_FILE" ]; then
    wget -q "$DEB_URL" -O "$DEB_FILE"
fi

sudo dpkg -i "$DEB_FILE" || sudo apt-get install -f -y
echo "[OK] Arc installed"

# ============================================================
# 2. PRINT SYSTEM INFO (Arc defaults)
# ============================================================
CORES=$(nproc)
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
MEM_LIMIT_GB=$((TOTAL_MEM_GB * 80 / 100))  # 80% of system RAM

echo ""
echo "System Configuration:"
echo "  CPU cores:    $CORES"
echo "  Connections:  $((CORES * 2)) (cores × 2)"
echo "  Threads:      $CORES (same as cores)"
echo "  Memory limit: ${MEM_LIMIT_GB}GB (80% of ${TOTAL_MEM_GB}GB total)"
echo ""

# ============================================================
# 3. START ARC AND CAPTURE TOKEN FROM LOGS
# ============================================================
echo "Starting Arc service..."

# Clear any existing Arc journal logs to ensure we capture fresh token
sudo journalctl --rotate --vacuum-time=1s -u arc >/dev/null 2>&1 || true

sudo systemctl start arc

# Wait for Arc to be ready and extract token from logs
echo "Waiting for Arc to start and generate token..."
ARC_TOKEN=""
for i in {1..30}; do
    # Check if service is running
    if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
        # Extract token from journald logs
        ARC_TOKEN=$(sudo journalctl -u arc --no-pager | grep -oP 'Initial admin API token: \K[^\s]+' | head -1)
        if [ -n "$ARC_TOKEN" ]; then
            echo "[OK] Arc is ready, token captured"
            break
        fi
    fi
    if [ $i -eq 30 ]; then
        echo "Error: Arc failed to start within 30 seconds"
        sudo journalctl -u arc --no-pager | tail -50
        exit 1
    fi
    sleep 1
done

# Save token for run.sh
echo "$ARC_TOKEN" > arc_token.txt
echo "Token: ${ARC_TOKEN:0:20}..."

# ============================================================
# 4. DOWNLOAD DATASET
# ============================================================
DATASET_FILE="hits.parquet"
DATASET_URL="https://datasets.clickhouse.com/hits_compatible/hits.parquet"
EXPECTED_SIZE=14779976446

if [ -f "$DATASET_FILE" ]; then
    CURRENT_SIZE=$(stat -c%s "$DATASET_FILE" 2>/dev/null || stat -f%z "$DATASET_FILE" 2>/dev/null)
    if [ "$CURRENT_SIZE" -eq "$EXPECTED_SIZE" ]; then
        echo "[OK] Dataset already downloaded (14GB)"
    else
        echo "Re-downloading dataset (size mismatch)..."
        rm -f "$DATASET_FILE"
        wget --continue --progress=dot:giga "$DATASET_URL"
    fi
else
    echo "Downloading ClickBench dataset (14GB)..."
    wget --continue --progress=dot:giga "$DATASET_URL"
fi

# ============================================================
# 5. LOAD DATA INTO ARC
# ============================================================
echo "Loading data into Arc..."

# Determine Arc's data directory (default: /var/lib/arc/data)
ARC_DATA_DIR="/var/lib/arc/data"
TARGET_DIR="$ARC_DATA_DIR/arc/clickbench/hits"
TARGET_FILE="$TARGET_DIR/hits.parquet"

sudo mkdir -p "$TARGET_DIR"

if [ -f "$TARGET_FILE" ]; then
    SOURCE_SIZE=$(stat -c%s "$DATASET_FILE" 2>/dev/null || stat -f%z "$DATASET_FILE" 2>/dev/null)
    TARGET_SIZE=$(stat -c%s "$TARGET_FILE" 2>/dev/null || stat -f%z "$TARGET_FILE" 2>/dev/null)
    if [ "$SOURCE_SIZE" -eq "$TARGET_SIZE" ]; then
        echo "[OK] Data already loaded"
    else
        echo "Reloading data (size mismatch)..."
        sudo cp "$DATASET_FILE" "$TARGET_FILE"
    fi
else
    sudo cp "$DATASET_FILE" "$TARGET_FILE"
    echo "[OK] Data loaded to $TARGET_FILE"
fi

# ============================================================
# 6. SET ENVIRONMENT AND RUN BENCHMARK
# ============================================================
export ARC_URL="http://localhost:8000"
export ARC_API_KEY="$ARC_TOKEN"
export DATABASE="clickbench"
export TABLE="hits"

echo ""
echo "Running ClickBench queries (true cold runs)..."
echo "================================================"
./run.sh 2>&1 | tee log.txt

# ============================================================
# 7. STOP ARC AND FORMAT RESULTS
# ============================================================
echo "Stopping Arc..."
sudo systemctl stop arc

# Format results
cat log.txt | grep -oE '^[0-9]+\.[0-9]+|^null' | \
  awk '{
    if (NR % 3 == 1) printf "[";
    printf "%s", $1;
    if (NR % 3 == 0) print "]";
    else printf ", ";
  }' > results.txt

echo ""
echo "[OK] Benchmark complete!"
echo "================================================"
echo "Load time: 0"
echo "Data size: $EXPECTED_SIZE"
cat results.txt
echo "================================================"

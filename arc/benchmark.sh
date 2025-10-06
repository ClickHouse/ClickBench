#!/bin/bash
# Arc ClickBench Complete Benchmark Script
# This script installs Arc, loads data, and runs the benchmark

set -e

# Install Python and dependencies
echo "Installing dependencies..."
pip3 install duckdb requests

# Download and prepare dataset
echo "Downloading ClickBench dataset..."
wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

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

# Run benchmark
echo "Running ClickBench queries..."
./run.sh 2>&1 | tee log.txt

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

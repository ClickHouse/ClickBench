#!/bin/bash
# ParticleDB ClickBench Benchmark
# Automated setup for a fresh Ubuntu 24.04 VM (tested on c8g.metal-48xl, 384GB RAM)

set -euo pipefail

# Install Rust
if ! command -v rustc &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# Install build dependencies
sudo apt-get update
sudo apt-get install -y build-essential libssl-dev pkg-config

# Extract source (assumes particledb-src.tar.gz is in current directory)
if [ ! -d "particledb" ]; then
    mkdir -p particledb
    tar xzf particledb-src.tar.gz -C particledb
fi
cd particledb

# Build in release mode
cargo build --release -p spanner-integration-tests

# Download ClickBench hits.parquet (14GB, ~100M rows)
mkdir -p benchmarks/clickbench/data
if [ ! -f "benchmarks/clickbench/data/hits.parquet" ]; then
    wget -c 'https://datasets.clickhouse.com/hits_compatible/hits.parquet' \
        -O benchmarks/clickbench/data/hits.parquet
fi

echo "============================================================"
echo "  Running ParticleDB ClickBench (real hits.parquet)"
echo "============================================================"

# Run the benchmark (loads parquet, runs all 43 queries x 3 runs each)
CLICKBENCH_MACHINE="${CLICKBENCH_MACHINE:-c8g.metal-48xl}" \
    cargo test -p spanner-integration-tests --release test_clickbench_real_hits -- --nocapture 2>&1 | tee /tmp/clickbench_results.log

# Extract key metrics
echo ""
echo "============================================================"
echo "  Results Summary"
echo "============================================================"
grep 'CLICKBENCH_SUBMISSION_JSON_START' -A 100 /tmp/clickbench_results.log | \
    sed -n '/^{/,/^}/p' > /tmp/clickbench_submission.json
echo "Submission JSON written to /tmp/clickbench_submission.json"
cat /tmp/clickbench_submission.json

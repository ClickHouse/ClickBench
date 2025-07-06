#!/bin/bash

set -euo pipefail

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > rust-init.sh
bash rust-init.sh -y
export HOME=${HOME:=~}
source ~/.cargo/env

# Install Dependencies
sudo apt-get update -y
sudo apt-get install -y gcc jq build-essential

# Install Vortex from latest release main branch
git clone https://github.com/spiraldb/vortex.git || true
cd vortex
git checkout 0.34.0
git submodule update --init
# We build a release version of the benchmarking utility using mimalloc, just like the datafusion-cli
cargo build --release --bin clickbench --package bench-vortex
export PATH="`pwd`/target/release:$PATH"
cd ..

# Vortex's benchmarking utility generates appropriate Vortex files by itself, so we just run it to make sure they exist before we start measuring.
# This will download parquet files (with time and string columns already converted to the logically correct datatype) and generate Vortex files from them.
echo -n "Load time: "
command time -f '%e' clickbench -i 1 --targets datafusion:vortex --display-format gh-json -q 0 --hide-progress-bar --flavor single

# Run benchmarks for single parquet and partitioned, our CLI generates the relevant vortex files.
./run.sh single

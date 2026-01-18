#!/bin/bash

echo "Install Rust"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > rust-init.sh
bash rust-init.sh -y
export HOME=${HOME:=~}
source ~/.cargo/env

echo "Install Dependencies"
sudo apt-get update -y
sudo apt-get install -y gcc

echo "Install DataFusion main branch"
git clone https://github.com/apache/datafusion.git
cd datafusion/
git checkout 52.0.0
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
CARGO_PROFILE_RELEASE_LTO=true RUSTFLAGS="-C codegen-units=1" cargo build --release --package datafusion-cli --bin datafusion-cli
sudo swapoff /swapfile
export PATH="`pwd`/target/release:$PATH"
cd ..

echo "Download benchmark target data, single file"
wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/hits.parquet

echo "Run benchmarks"
./run.sh

echo "Load time: 0"
echo "Data size: $(du -bcs hits.parquet)"

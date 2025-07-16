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
git clone https://github.com/apache/arrow-datafusion.git
cd arrow-datafusion/
git checkout 47.0.0
CARGO_PROFILE_RELEASE_LTO=true RUSTFLAGS="-C codegen-units=1" cargo build --release --package datafusion-cli --bin datafusion-cli
export PATH="`pwd`/target/release:$PATH"
cd ..

echo "Download benchmark target data, single file"
../lib/download-parquet.sh

echo "Run benchmarks"
./run.sh

echo "Load time: 0"
echo "Data size: $(du -bcs hits.parquet)"

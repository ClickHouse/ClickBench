#!/bin/bash

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > rust-init.sh
bash rust-init.sh -y
source ~/.cargo/env


# Install Dependencies
sudo apt update -y
sudo apt install gcc -y


# Install Datafusion
#cargo install --version 10.0.0 datafusion-cli

# Install Datafusion Master Branch
git clone https://github.com/apache/arrow-datafusion.git
cd arrow-datafusion/datafusion-cli
CARGO_PROFILE_RELEASE_LTO=true RUSTFLAGS="-C codegen-units=1" cargo build --release
export PATH="`pwd`/target/release:$PATH"
cd ../..


# Download benchmark target data
wget --continue https://datasets.clickhouse.com/hits_compatible/hits.parquet


# Run
bash run.sh

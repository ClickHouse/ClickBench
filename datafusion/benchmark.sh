#!/bin/bash

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > rust-init.sh
bash rust-init.sh -y
source .cargo/env


# Install Dependencies
sudo apt update -y
sudo apt install gcc -y


# Install Datafusion
cargo install --version 10.0.0 datafusion-cli


# Download benchmark target data
wget --continue https://datasets.clickhouse.com/hits_compatible/hits.parquet


# Run
bash run.sh

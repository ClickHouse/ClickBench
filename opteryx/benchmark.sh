#!/bin/bash

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > rust-init.sh
bash rust-init.sh -y
source ~/.cargo/env

apt-get update
apt-get install -y python3-pip

# Install Opteryx main branch
git clone https://github.com/mabel-dev/opteryx.git
cd opteryx
python -m pip install --upgrade -r requirements.txt
python -m pip install --upgrade -r tests/requirements.txt
make compile

# Download benchmark target data, partitioned
mkdir -p hits
seq 0 99 | xargs -P100 -I{} bash -c 'wget --no-verbose --directory-prefix hits --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Run benchmarks for partitioned
cd ..
./run.sh


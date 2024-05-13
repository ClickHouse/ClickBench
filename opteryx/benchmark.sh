#!/bin/bash

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > rust-init.sh
bash rust-init.sh -y
source ~/.cargo/env

# Update package lists
apt-get update

# Install required packages
apt-get install -y python3-full python3-venv git wget

# Create and activate a virtual environment
python3 -m venv ~/opteryx_venv
source ~/opteryx_venv/bin/activate

# Upgrade pip in the virtual environment
~/opteryx_venv/bin/python -m pip install --upgrade pip

# Clone the Opteryx repository and install dependencies
git clone https://github.com/mabel-dev/opteryx.git
cd opteryx
~/opteryx_venv/bin/python -m pip install --upgrade -r requirements.txt
~/opteryx_venv/bin/python -m pip install --upgrade -r tests/requirements.txt

# Compile Opteryx
make compile

# Download benchmark target data, partitioned
mkdir -p hits
seq 0 99 | xargs -P100 -I{} bash -c 'wget --no-verbose --directory-prefix hits --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Run a simple query to check the installation
~/opteryx_venv/bin/python -m opteryx "SELECT version()" 2>&1

# Run benchmarks for partitioned data using queries from queries.sql
if [[ -f ../queries.sql ]]; then
    while read -r query; do
        echo "$query"
        ~/opteryx_venv/bin/python -m opteryx "$query" --cycles 3 --o "null.parquet" 2>&1
    done < ../queries.sql
else
    echo "queries.sql not found in the parent directory."
fi

# Deactivate the virtual environment
deactivate

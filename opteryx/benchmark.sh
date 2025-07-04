#!/bin/bash

# Update package lists
sudo apt-get update
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt-get update

# Install required packages
sudo apt-get install -y python3.11 python3.11-venv git wget build-essential python3.11-dev

# Create and activate a virtual environment using Python 3.11
python3.11 -m venv ~/opteryx_venv
source ~/opteryx_venv/bin/activate

# Upgrade pip in the virtual environment
~/opteryx_venv/bin/python -m pip install --upgrade pip
~/opteryx_venv/bin/python -m pip install --upgrade opteryx==0.21.0

# Download benchmark target data, partitioned
mkdir -p hits
seq 0 99 | xargs -P100 -I{} bash -c 'wget --directory-prefix hits --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Run a simple query to check the installation
~/opteryx_venv/bin/python -m opteryx "SELECT version()" 2>&1

# Run benchmarks for partitioned data using queries from queries.sql
if [[ -f ./queries.sql ]]; then
    while read -r query; do
        sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches

        ~/opteryx_venv/bin/python -m opteryx "$query" --cycles 3 2>&1
    done < ./queries.sql
else
    echo "queries.sql not found."
fi

# Deactivate the virtual environment
deactivate

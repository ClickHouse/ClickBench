#!/bin/bash

# Install
sudo apt-get update
sudo apt-get install -y python3-pip
pip install --break-system-packages pandas
pip install --break-system-packages packaging
pip install --break-system-packages daft==0.4.9

# Use for Daft (Parquet, partitioned)
# seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Use for Daft (Parquet, single)
wget --continue https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet

# Run the queries
./run.sh 2>&1 | tee daft_log.txt
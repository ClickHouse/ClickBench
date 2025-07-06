#!/bin/bash

# Install
sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv
python3 -m venv myenv
source myenv/bin/activate
pip install pandas
pip install packaging
pip install daft

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet'

# Run the queries
mode=single
echo "Running $mode mode..."
./run.sh $mode 2>&1 | tee "daft_log_${mode}.txt"

echo "Load time: 0"
echo "Data size: $(du -bcs hits.parquet)"

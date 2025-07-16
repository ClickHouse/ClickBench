#!/bin/bash

# Install
sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv
python3 -m venv myenv
source myenv/bin/activate
pip install pandas
pip install packaging
pip install daft==0.4.13

../lib/download-parquet-partitioned.sh

mode=partitioned
echo "Running $mode mode..."
./run.sh $machine_name $mode 2>&1 | tee "daft_log_${mode}.txt"

echo "Load time: 0"
echo "Data size: $(du -bcs hits*.parquet | grep total)"

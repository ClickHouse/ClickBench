#!/bin/bash

machine=${1:-"c6a.4xlarge"}
case "$machine" in
    "c6a.4xlarge"|"c6a.metal")
        machine_name="$machine"
        ;;
    *)
        echo "Invalid machine parameter. Allowed: c6a.4xlarge or c6a.metal"
        exit 1
        ;;
esac

# Install
sudo apt-get update
sudo apt-get install -y python3-pip
pip install --break-system-packages pandas
pip install --break-system-packages packaging
pip install --break-system-packages daft==0.4.13

# Use for Daft (Parquet, partitioned)
seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Use for Daft (Parquet, single)
wget --continue https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet

# Run the queries
for mode in partitioned single; do
    echo "Running $mode mode..."
    ./run.sh $machine_name $mode 2>&1 | tee "daft_log_${mode}.txt"
done

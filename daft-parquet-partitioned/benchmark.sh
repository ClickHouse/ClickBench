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
pip install pandas
pip install packaging
pip install daft==0.4.13

seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

mode=partitioned
echo "Running $mode mode..."
./run.sh $machine_name $mode 2>&1 | tee "daft_log_${mode}.txt"

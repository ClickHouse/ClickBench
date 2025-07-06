#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y python3-pip

PIP_MAJOR=$(echo $(pip --version | awk '{print $2}') | cut -d. -f1)
if [ $PIP_MAJOR -ge 23 ]; then
    pip install tableauhyperapi
else
    pip install tableauhyperapi
fi

if [ ! -f hits_0.parquet ]; then
    seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'
fi

./run.sh | tee log.txt
echo "Data size: $(du -bcs hits*.parquet | grep total)"
echo "Load time: 0"

cat log.txt | awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

#!/bin/bash

# Install

export DEBIAN_FRONTEND=noninteractive
export TZ=Etc/UTC
sudo ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

sudo apt-get update
sudo apt-get install -y software-properties-common
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt-get update
sudo apt-get install -y python3.11 python3.11-dev python3.11-venv python3.11-distutils

sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 && \
     sudo update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1 && \
     curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11

pip install --upgrade setuptools wheel
pip install pysail[spark]==0.2.6 pandas psutil

# Load the data

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Run the queries

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -P '^Time:\s+([\d\.]+)|Failure!' | sed -r -e 's/Time: //; s/^Failure!$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo "Data size: $(du -b hits.parquet)"

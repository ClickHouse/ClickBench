#!/bin/bash

# https://github.com/rust-lang/rust/issues/97234#issuecomment-1133564556
ulimit -n 65536

# Install

export DEBIAN_FRONTEND=noninteractive

# When you run Sail on Amazon Linux, you may encounter the following error:
#    failed to get system time zone: No such file or directory (os error 2)
# The reason is that /etc/localtime is supposed to be a symlink when retrieving the system time zone, but on Amazon Linux it is a regular file.
# There is a GitHub issue for this problem, but it has not been resolved yet: https://github.com/amazonlinux/amazon-linux-2023/issues/526
echo "Set Timezone"
export TZ=Etc/UTC
sudo ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

echo "Install Rust"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > rust-init.sh
bash rust-init.sh -y
export HOME=${HOME:=~}
source ~/.cargo/env

echo "Install Dependencies"
sudo apt-get update -y
sudo apt-get install -y software-properties-common
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt-get update -y
sudo apt-get install -y \
     gcc protobuf-compiler \
     libprotobuf-dev \
     pkg-config \
     libssl-dev \
     python3.11 \
     python3.11-dev \
     python3.11-venv \
     python3.11-distutils

echo "Set Python alternatives"
sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 && \
     sudo update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1 && \
     curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11

echo "Install Python packages"
python3 -m venv myenv
source myenv/bin/activate
pip install --upgrade setuptools wheel
pip install --no-cache-dir "pysail>=0.4.6,<0.6.0"
pip install "pyspark-client==4.1.1" \
  pandas \
  psutil

# Load the data

echo "Download benchmark target data, single file"
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Run the queries

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -P '^Time:\s+([\d\.]+)|Failure!' | sed -r -e 's/Time: //; s/^Failure!$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo "Data size: $(du -b hits.parquet)"
echo "Load time: 0"

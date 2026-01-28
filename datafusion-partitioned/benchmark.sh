#!/bin/bash

echo "Install Dependencies"
sudo apt-get update -y

echo "Install Homebrew"
# This requires password input for sudo, which is not set by default.
# You may need to run the following command to set a password first:
# ```
# sudo su
# passwd ubuntu
# exit
# ```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo >> /home/ubuntu/.bashrc
echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"' >> /home/ubuntu/.bashrc
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"

echo "Install datafusion-cli"
# or use `brew install datafusion@52` to install a specific version
brew install datafusion
datafusion-cli --version

echo "Download benchmark target data, partitioned"
mkdir -p partitioned
seq 0 99 | xargs -P100 -I{} bash -c 'wget --directory-prefix partitioned --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

echo "Run benchmarks for single parquet and partitioned"
./run.sh

echo "Load time: 0"
echo "Data size: $(du -bcs partitioned | grep total)"

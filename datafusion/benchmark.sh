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

echo "Download benchmark target data, single file"
wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/hits.parquet

echo "Run benchmarks"
./run.sh

echo "Load time: 0"
echo "Data size: $(du -bcs hits.parquet)"

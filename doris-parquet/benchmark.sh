#!/bin/bash

set -ex

# This benchmark should run on Ubuntu 22.04

# Install
url='https://apache-doris-releases.oss-accelerate.aliyuncs.com/apache-doris-3.0.5-bin-x64.tar.gz'
# Download
file_name="$(basename ${url})"
if [[ "$url" == "http"* ]]; then
    if [[ ! -f $file_name ]]; then
        wget --continue ${url}
    else
        echo "$file_name already exists, no need to download."
    fi
fi
dir_name="${file_name/.tar.gz/}"

# Try to stop Doris and remove it first if execute this script multiple times
set +e
"$dir_name"/apache-doris-3.0.5-bin-x64/fe/bin/stop_fe.sh
"$dir_name"/apache-doris-3.0.5-bin-x64/be/bin/stop_be.sh
rm -rf "$dir_name"
set -e

# Uncompress
mkdir "$dir_name"
tar zxf "$file_name" -C "$dir_name"
DORIS_HOME="$dir_name/apache-doris-3.0.5-bin-x64"
export DORIS_HOME

# Install dependencies
sudo apt update
sudo apt install -y openjdk-17-jdk
sudo apt install -y mysql-client
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64/"
export PATH=$JAVA_HOME/bin:$PATH

sudo systemctl disable unattended-upgrades
sudo systemctl stop unattended-upgrades

"$DORIS_HOME"/fe/bin/start_fe.sh --daemon

# Start Backend
sudo sysctl -w vm.max_map_count=2000000
ulimit -n 65535
"$DORIS_HOME"/be/bin/start_be.sh --daemon

# Wait for Frontend ready
while true; do
    fe_version=$(mysql -h127.0.0.1 -P9030 -uroot -e 'show frontends' | cut -f16 | sed -n '2,$p')
    if [[ -n "${fe_version}" ]] && [[ "${fe_version}" != "NULL" ]]; then
        echo "Frontend version: ${fe_version}"
        break
    else
        echo 'Wait for Frontend ready ...'
        sleep 2
    fi
done

# Setup cluster, add Backend to cluster
mysql -h 127.0.0.1 -P9030 -uroot -e "ALTER SYSTEM ADD BACKEND '127.0.0.1:9050' "

# Wait for Backend ready
while true; do
    be_version=$(mysql -h127.0.0.1 -P9030 -uroot -e 'show backends' | cut -f22 | sed -n '2,$p')
    if [[ -n "${be_version}" ]]; then
        echo "Backend version: ${be_version}"
        break
    else
        echo 'Wait for Backend ready ...'
        sleep 2
    fi
done

# Download Parquet files
cd "$DORIS_HOME/be"
seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'
cd -

# Run the queries
mysql -h127.1 -P9030 -uroot -vvv < create.sql
./run.sh 2>&1 | tee run.log
date

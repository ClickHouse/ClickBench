#!/bin/bash

# This benchmark should run on Amazon Linux

set -e

VERSION=3.5.6-ubuntu-$(dpkg --print-architecture)
# Install
wget --continue --progress=dot:giga https://releases.starrocks.io/starrocks/StarRocks-$VERSION.tar.gz -O StarRocks-$VERSION.tar.gz
tar zxvf StarRocks-${VERSION}.tar.gz
mv StarRocks-3.5.6-ubuntu-amd64 StarRocks
cd StarRocks/

# Install dependencies
sudo apt-get update -y
sudo apt-get install -y openjdk-17-jre mariadb-client
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)
export PATH=$JAVA_HOME/bin:$PATH

# Create directory for FE and BE
IPADDR=`hostname -i`
export STARROCKS_HOME=`pwd`
mkdir -p meta storage

# Start Frontend
echo "meta_dir = ${STARROCKS_HOME}/meta " >> fe/conf/fe.conf
fe/bin/start_fe.sh --daemon

# Start Backend
echo "storage_root_path = ${STARROCKS_HOME}/storage" >> be/conf/be.conf
be/bin/start_be.sh --daemon

# Setup cluster
# wait some seconds util fe can serve
sleep 30
mysql -h 127.0.0.1 -P9030 -uroot -e "ALTER SYSTEM ADD BACKEND '${IPADDR}:9050' "
# wait some seconds util be joins
sleep 30

# Prepare Data
cd "$STARROCKS_HOME/be"
seq 0 99 | xargs -P100 -I '{}' bash -c 'wget --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'
cd "$STARROCKS_HOME/../"

# Create Table
mysql -h 127.0.0.1 -P9030 -uroot -e "CREATE DATABASE IF NOT EXISTS hits"
mysql -h 127.0.0.1 -P9030 -uroot hits < create.sql

# Run queries
./run.sh 2>&1 | tee -a log.txt

cat log.txt |
  grep -P 'rows? in set|Empty set|^ERROR' |
  sed -r -e 's/^ERROR.*$/null/; s/^.*?\((([0-9.]+) min )?([0-9.]+) sec\).*?$/\2 \3/' |
  awk '{ if ($2 != "") { print $1 * 60 + $2 } else { print $1 } }' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

#!/bin/bash

# Install
wget https://github.com/StarRocks/starrocks/archive/refs/tags/2.3.0-rc02.tar.gz -O starrocks-2.3.0.tar.gz
tar zxvf starrocks-2.3.0.tar.gz
cd starrocks-2.3.0/

# Create directory for FE and BE
BASEDIR=`pwd`
mkdir -p meta storage
export STARROCKS_HOME=$BASEDIR

# Start Frontend
echo "meta_dir = ${STARROCKS_HOME}/meta " >> fe/conf/fe.conf
fe/bin/start_fe.sh --daemon

# Start Backend
echo "storage_root_path = ${STARROCKS_HOME}/storage" >> be/conf/be.conf
echo "disable_storage_page_cache = false" >> be/conf/be.conf
be/bin/start_be.sh --daemon

# Setup cluster
mysql -h 127.0.0.1 -P9030 -uroot -e "ALTER SYSTEM ADD BACKEND '127.0.0.1:8030' "


# Load data
wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
gzip -d hits.csv.gz
split -a 2 -d -l 10000000 hits_all_signed_utf8.csv hits_all_signed_split
for i in `seq -w 0 9`; do
    echo "start importing hits_all_signed_split${i} ..."
    curl --location-trusted \
        -u root: \
        -T "hits_all_signed_split${i}" \
        -H "label:hits_signed_${i}" \
        http://localhost:8030/api/hits/hits_signed/_stream_load
done

# Total bytes
du -bcs storage/
wc -l hits.csv

# Run queries
./run.sh 2>&1 | tee run.log

#!/bin/bash

if [ ! -x /usr/bin/clickhouse ]
then
wget --continue --progress=dot:giga https://clickhouse-builds.s3.amazonaws.com/PRs/81944/cda07f8aca770d97ea149eec6b477dcfd59d134e/build_amd_release/clickhouse-common-static-25.7.1.1-amd64.tgz -O clickhouse-tencent.tgz
    mkdir -p clickhouse-tencent && tar -xzf clickhouse-tencent.tgz -C clickhouse-tencent
    sudo clickhouse-tencent/clickhouse-common-static-25.7.1.1/usr/bin/clickhouse install --noninteractive
fi

sudo clickhouse start

while true
do
    clickhouse-client --query "SELECT 1" && break
    sleep 1
done

clickhouse-client < create.sql

if [ ! -f hits.tsv ]
then
    sudo apt-get install -y pigz
    wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
    pigz -d -f hits.tsv.gz
fi

echo -n "Load time: "
clickhouse-client --time --query "INSERT INTO hits FORMAT TSV" < hits.tsv

# Run the queries

./run.sh "$1"

echo -n "Data size: "
clickhouse-client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"

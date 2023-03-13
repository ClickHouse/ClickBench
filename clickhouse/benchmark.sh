#!/bin/bash

set -x

# -t -- generate tuned results
# -z -- use zstd as compression method
while getopts "tz" arg
do
  case $arg in
    t)
      tuned=1
      ;;
    z)
      use_zstd=1
      ;;
  esac
done

# Install

curl https://clickhouse.com/ | sh
sudo DEBIAN_FRONTEND=noninteractive ./clickhouse install

# Clean up non-default config files:
sudo rm -f /etc/clickhouse-server/config.d/compression.yaml
sudo rm -f /etc/clickhouse-server/users.d/custom-settings.yaml

if (( use_zstd )); then
    echo "
compression:
    case:
        method: zstd
    " | sudo tee /etc/clickhouse-server/config.d/compression.yaml
fi;

sudo clickhouse restart

# Load the data

cpus=$(lscpu -J | jq '.lscpu[] | select(.field=="CPU(s):") | .data' | bc)
cpus=16

if (( ! tuned )); then
    clickhouse-client < create.sql
else
    echo "
profiles:
    default:
        max_partitions_per_insert_block: 1000
        allow_aggregate_partitions_independently: true
        # force_aggregate_partitions_independently: true
    " | sudo tee /etc/clickhouse-server/users.d/custom-settings.yaml

    sudo clickhouse restart

    cp create-tuned.tmpl create-tuned.sql
    sed -i "s/MAX_THREADS/$cpus/g" create-tuned.sql
    clickhouse-client < create-tuned.sql
    rm create-tuned.sql
fi;

# wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
# gzip -d hits.tsv.gz

clickhouse-client --time --query "INSERT INTO hits FORMAT TSV" < hits.tsv

# Run the queries

./run.sh $tuned

clickhouse-client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"

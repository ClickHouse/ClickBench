#!/bin/bash

# Install

if [ ! -x /usr/bin/clickhouse ]
then
    cd /tmp || exit
    curl https://clickhouse.com/ | sh
    sudo ./clickhouse install --noninteractive
    rm clickhouse
    cd - || exit
fi

# Optional: if you want to use higher compression:
if (( 0 )); then
    echo "
compression:
    case:
        method: zstd
    " | sudo tee /etc/clickhouse-server/config.d/compression.yaml
fi;

sudo clickhouse start

for _ in {1..300}
do
    clickhouse-client --query "SELECT 1" && break
    sleep 1
done

# Determine which set of files to use depending on the type of run
if [ "$1" != "" ] && [ "$1" != "tuned" ] && [ "$1" != "tuned-memory" ]; then
    echo "Error: command line argument must be one of {'', 'tuned', 'tuned-memory'}"
    exit 1
elif [ ! -z "$1" ]; then
    SUFFIX="-$1"
fi

# Load the data

clickhouse-client < create"$SUFFIX".sql

TOTAL_PARTITIONS=${TOTAL_PARTITIONS:-100}

seq 0 "$((TOTAL_PARTITIONS-1))" | xargs -P100 -I{} bash -c 'wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'
mkdir -p /var/lib/clickhouse/user_files
sudo mv hits_*.parquet /var/lib/clickhouse/user_files/
sudo chown clickhouse:clickhouse /var/lib/clickhouse/user_files/hits_*.parquet

sync

start=$(date +%s.%N)

clickhouse-client --query "INSERT INTO hits SELECT * FROM file('hits_*.parquet')" --max-insert-threads $(( $(nproc) / 4 ))
sync

end=$(date +%s.%N)
elapsed=$(echo "$end - $start" | bc)

echo "Load time: $elapsed s"

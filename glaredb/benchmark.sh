#!/bin/bash

# Install

sudo apt-get install -y unzip
curl https://glaredb.com/install.sh | sh

wget https://clickhouse-public-datasets.s3.eu-central-1.amazonaws.com/hits_compatible/athena/hits.parquet

cat queries.sql | while read query
do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    for i in $(seq 1 3); do
        ./glaredb --timing --query "${query}"
    done;
done 2>&1 | tee log.txt

cat log.txt | grep -oP 'Time: \d+\.\d+s|Error' | sed -r -e 's/Time: ([0-9]+\.[0-9]+)s/\1/; s/Error/null/' | awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

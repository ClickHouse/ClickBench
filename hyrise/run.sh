#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    echo "$query"
    for i in $(seq 1 $TRIES); do
        if output=$(psql -h 127.0.0.1 -p 5432 -U postgres -t -c '\timing' -c "$query" 2>&1); then
            echo "$output" | grep -oP 'Time: \d+\.\d+ ms' | tail -n1
        else
            echo "psql: error"
        fi
    done
done

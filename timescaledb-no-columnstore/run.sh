#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query";
    for i in $(seq 1 $TRIES); do
        sudo -u postgres psql nocolumnstore -t -c '\timing' -c "$query" | grep 'Time'
    done;
done;

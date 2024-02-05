#!/bin/bash

TRIES=3

cat queries.sql | while read query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query";
    for i in $(seq 1 $TRIES); do
        sudo psql -h localhost -p 5432 -U postgres -d test -t -c '\timing' -c "$query" | grep 'Time'
    done;
done;

#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query";
    for i in $(seq 1 $TRIES); do
        psql postgres://postgres:duckdb@localhost:5432/postgres -t -c '\timing' -c "$query" | grep 'Time'
    done;
done;

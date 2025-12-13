#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query";
    for i in $(seq 1 $TRIES); do
        PGPASSWORD='<PASSWORD>' psql -h 127.0.0.1 -p 5432 -U postgres -d clickbenc -c "$query" 2>&1 | grep -P 'Time|psql: error' | tail -n1
    done;
done;

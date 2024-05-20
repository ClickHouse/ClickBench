#!/bin/bash

TRIES=3
export PGPASSWORD='mypassword'

cat queries.sql | while read query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query";
    for i in $(seq 1 $TRIES); do
    psql -h localhost -U myuser -d mydb -p 5432 -t -c '\timing' -c "$query" | grep 'Time'
    done;
done;

#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query"
    for i in $(seq 1 $TRIES); do
        echo -e "\\\timing\n$query" | docker exec -i pgduck psql -U postgres -d test -t | grep 'Time'
    done
done

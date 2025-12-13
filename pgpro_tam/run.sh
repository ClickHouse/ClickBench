#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    sudo sysctl vm.drop_caches=3

    echo "$query"
    (
        echo '\timing'
        yes "$query" | head -n $TRIES
    ) | psql -h 127.0.0.1 -U postgres -t 2>&1 | grep -P 'Time|psql: error' | tail -n1
done;

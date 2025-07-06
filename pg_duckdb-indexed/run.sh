#!/bin/bash

TRIES=3

export PGUSER=postgres
export PGPASSWORD=duckdb

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query"
    (
        echo '\timing'
        yes "$query" | head -n $TRIES
    ) | psql $CONNECTION --no-psqlrc --tuples-only | grep 'Time'
done

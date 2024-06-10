#!/bin/bash

TRIES=3
export PGPASSWORD='postgres'

cat queries.sql | while read query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query";
    output=$(psql -h localhost -U postgres -d mydb -p 5432 -t -c "CALL connect_table('hits')"  -c '\timing' -c "$query" -c "$query" -c "$query")
    echo "$output" | grep 'Time'
done;

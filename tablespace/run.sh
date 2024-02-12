#!/bin/bash

TRIES=3

cat queries.sql | while read query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query";
    for i in $(seq 1 $TRIES); do
       psql 'host=<hostname> port=5432 dbname=csdb user=csuser password=<password> sslmode=require' -c '\timing' -c "$query" | grep 'Time'
    done;
done;
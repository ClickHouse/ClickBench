#!/bin/bash

TRIES=3
HOSTNAME="<tablespace-db-hostname>"
PASSWORD="<tablespace-db-password>"

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query";
    for i in $(seq 1 $TRIES); do
       psql "host=$HOSTNAME port=5432 dbname=csdb user=csuser password=$PASSWORD sslmode=require" -c '\timing' -c "$query" | grep 'Time'
    done;
done;
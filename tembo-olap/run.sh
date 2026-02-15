#!/bin/bash

HOSTNAME=$1
PASSWORD=$2

TRIES=3

cat queries.sql | while read -r query; do
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
    echo "$query";
    for i in $(seq 1 $TRIES); do
	    psql "host=$HOSTNAME port=5432 dbname=test user=postgres password=$PASSWORD sslmode=require" -t -c '\timing' -c "$query" 2>&1 | grep -P 'Time|psql: error' | tail -n1
    done;
done;

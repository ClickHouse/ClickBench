#!/bin/bash

HOSTNAME=$1
PASSWORD=$2

TRIES=3

cat queries.sql | while read -r query; do
    echo "$query";
    for i in $(seq 1 $TRIES); do
	    psql "host=$HOSTNAME port=5432 dbname=test user=postgres password=$PASSWORD sslmode=require" -t -c '\timing' -c "$query" | grep 'Time'
    done;
done;

#!/bin/bash

PG_USER=$1
PG_PASSWORD=$2
HOST_NAME=$3
PORT=$4
DB=$5

TRIES=3

PGUSER=$PG_USER PGPASSWORD=$PG_PASSWORD psql -h $HOST_NAME -p $PORT -d $DB -t < prepare.sql


cat queries.sql | while read query; do
    echo 'freecache begin'
    PGUSER=$PG_USER PGPASSWORD=$PG_PASSWORD psql -h $HOST_NAME -p $PORT -d $DB -t -f freecache.sql
    echo 'freecache end'

    temp_file=$(mktemp)
    echo $query
    echo '\timing' >> $temp_file
    for i in $(seq 1 $TRIES); do
        echo "$query" >> $temp_file
    done;
    PGUSER=$PG_USER PGPASSWORD=$PG_PASSWORD psql -h $HOST_NAME -p $PORT -d $DB -t -f $temp_file 2>&1 | grep -P 'ms|psql: error' | tail -n1
    rm "$temp_file"
done;

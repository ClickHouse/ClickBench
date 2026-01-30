#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    echo "$query";
    for i in $(seq 1 $TRIES); do
        psql -U postgres -h "${FQDN}" test -t -c '\timing' -c "$query" 2>&1 | grep -P 'Time|psql: error' | tail -n1
    done;
done;

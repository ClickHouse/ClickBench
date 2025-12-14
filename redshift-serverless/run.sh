#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    echo "$query";
    for i in $(seq 1 $TRIES); do
        psql -h "${FQDN}" -U awsuser -d dev -p 5439 -t -c 'SET enable_result_cache_for_session = off' -c '\timing' -c "$query" 2>&1 | grep -P 'Time|psql: error' | tail -n1
    done;
done;

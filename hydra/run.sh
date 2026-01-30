#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    echo "$query"
    (
	    echo "set search_path=clickbench;"
        echo '\timing on'
        yes "$query" | head -n $TRIES
    ) | psql $DATABASE_URL 2>&1 | grep -P 'Time|psql: error' | tail -n1
done

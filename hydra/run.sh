#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    echo "$query"
    (
	    echo "set search_path=clickbench;"
        echo '\timing on'
        yes "$query" | head -n $TRIES
    ) | psql $DATABASE_URL | grep 'Time'
done

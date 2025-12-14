#!/bin/bash

TRIES=3
CONNECTION=postgres://postgres:duckdb@localhost:5432/postgres

DATABASE='ddb$pgclick'

cat queries.sql | while read -r query; do
    echo "$query"
    (
        echo "set search_path=$DATABASE;"
        echo '\timing'
        yes "$query" | head -n $TRIES
    ) | psql --no-psqlrc --tuples-only $CONNECTION 2>&1 | grep -P 'Time|psql: error' | tail -n1
done

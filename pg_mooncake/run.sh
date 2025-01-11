#!/bin/bash

TRIES=3
CONNECTION=postgres://postgres:pg_mooncake@localhost:5432/postgres

cat queries.sql | while read query; do
    echo "$query"
    (
        echo '\timing'
        yes "$query" | head -n $TRIES
    ) | psql $CONNECTION | grep 'Time'
done
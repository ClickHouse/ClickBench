#!/bin/bash

TRIES=3
# Your docker may be set up to use localhost, if so edit ip address
# below.
CONNECTION=postgres://postgres:duckdb@172.17.0.2:5432/postgres

DATABASE='ddb$pgclick'

cat queries.sql | while read query; do
    echo "$query"
    (
	    echo "set search_path=$DATABASE;"
        echo '\timing'
        yes "$query" | head -n $TRIES
    ) | psql $CONNECTION | grep 'Time'
done

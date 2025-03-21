#!/bin/bash

TRIES=3
CONNECTION=postgres://postgres:pg_mooncake@localhost:5432/postgres

cat queries.sql | while read query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches 1>/dev/null

    echo "$query"
    (
        echo '\timing'
        yes "$query" | head -n $TRIES
    ) | psql $CONNECTION | grep 'Time'
done
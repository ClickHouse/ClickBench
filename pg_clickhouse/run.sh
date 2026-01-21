#!/bin/bash

TRIES=3
prefix=""
if [ -n "$EXPLAIN" ]; then
    prefix="EXPLAIN (ANALYZE, VERBOSE) "
fi

cat queries.sql | while read -r query; do
    sync
    [ -w /proc/sys ] && echo 3 | sudo tee /proc/sys/vm/drop_caches

    (
        echo '\timing'
        yes "$prefix$query" | head -n $TRIES
    ) | sudo -u postgres psql -e --no-psqlrc --tuples-only test 2>&1 # | grep -P 'Time|psql: error'
done

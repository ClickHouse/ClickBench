#!/bin/bash

MODE=$1
TRIES=3

if [[ $MODE == "tuned" ]]; then
    FILE_NAME="queries-tuned.sql"
else
    FILE_NAME="queries.sql"
fi;

cat $FILE_NAME | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query";
    for i in $(seq 1 $TRIES); do
        psql -U crate -h localhost --no-password -t -c '\timing' -c "$query" 2>&1 | grep -P 'Time|psql: error' | tail -n1
    done;
done;

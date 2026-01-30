#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query";
    for i in $(seq 1 $TRIES); do
	echo '\timing' > /tmp/query_temp.sql
	echo "$query" >> /tmp/query_temp.sql
        psql -d postgres -t -f /tmp/query_temp.sql 2>&1 | grep -P 'Time|psql: error' | tail -n1
    done;
done;

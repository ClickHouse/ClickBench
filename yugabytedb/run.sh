#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo "$query"
    (
        echo '\timing'
        yes "$query" | head -n $TRIES
    ) | ./yugabyte/bin/ysqlsh -U yugabyte -d test -t 2>&1 | grep -P 'Time|ysqlsh: error' | tail -n1
done

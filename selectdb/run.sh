#!/bin/bash

TRIES=3

while read -r query; do
    curl -sS http://127.0.0.1:8040/api/clear_cache/all
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    for i in $(seq 1 $TRIES); do
        mysql -vvv -h127.1 -P9030 -uroot hits -e "${query}"
    done

done < queries.sql

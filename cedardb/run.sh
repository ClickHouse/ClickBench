#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    docker restart $(docker ps -a -q)

    retry_count=0
    while [ $retry_count -lt 120 ]; do
        if PGPASSWORD=test psql -h localhost -U postgres -c "SELECT 'Ok';"; then
            break
        fi

        retry_count=$((retry_count+1))
        sleep 1
    done

    echo "$query";
    for i in $(seq 1 $TRIES); do
        PGPASSWORD=test psql -h localhost -U postgres -t -c '\timing' -c "$query" | grep 'Time'
    done
done

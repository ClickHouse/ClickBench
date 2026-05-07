#!/bin/bash

TRIES=3
QUERY_NUM=1

mapfile -t QUERIES < queries.sql

for query in "${QUERIES[@]}"; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    echo -n "["
    for i in $(seq 1 $TRIES); do
        START=$(date +%s.%N)
        sudo docker exec -i trino trino --catalog hive --schema clickbench \
            --output-format=NULL --execute "${query}" >/dev/null 2>&1
        EXIT=$?
        END=$(date +%s.%N)
        if [ "$EXIT" = "0" ]; then
            ELAPSED=$(echo "$END - $START" | bc)
            printf "%.3f" "$ELAPSED"
        else
            printf "null"
        fi
        [[ "$i" != "$TRIES" ]] && echo -n ", "
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done

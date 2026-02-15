#!/bin/bash

TRIES=3
QUERY_NUM=1

./clickhouse local --path . --query="$(cat create.sql)"
cat queries.sql | while read -r query; do
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches

    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES=$(./clickhouse local --path . --time --format Null --filesystem_cache_name cache --query="$query" 2>&1) # (*)
        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "

        echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    # (*) --format=Null is client-side formatting. The query result is still sent back to the client.

    QUERY_NUM=$((QUERY_NUM + 1))
done
./clickhouse local --path . --query="DROP TABLE hits"

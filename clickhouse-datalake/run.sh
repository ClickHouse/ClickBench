#!/bin/bash

TRIES=3
QUERY_NUM=1
cat queries.sql | while read -r query; do

    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES=$(./clickhouse local --time --format Null --filesystem_cache_name cache --progress 0 --query="$(cat create.sql); $query" 2>&1 | tail -n1)
        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "

        echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done

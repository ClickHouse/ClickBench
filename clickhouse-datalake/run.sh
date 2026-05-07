#!/bin/bash

TRIES=3
QUERY_NUM=1

./clickhouse local --path . --query="$(cat create.sql)"
cat queries.sql | while read -r query; do
    echo -n "["
    i=0
    while read -r RES; do
        [[ "$i" -gt 0 ]] && echo -n ", "
        [[ "$RES" =~ ^[0-9] ]] && echo -n "${RES}" || echo -n "null"
        echo "${QUERY_NUM},$((i+1)),${RES}" >> result.csv
        i=$((i+1))
    done <<< "$(./clickhouse local --path . --time --format Null --use_page_cache_for_object_storage 1 --query "$query; $query; $query" 2>&1)"
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done
./clickhouse local --path . --query="DROP TABLE hits"

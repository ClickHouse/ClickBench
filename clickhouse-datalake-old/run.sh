#!/bin/bash

TRIES=3
QUERY_NUM=1

./clickhouse local --path . --query="$(cat create.sql)"
cat queries.sql | while read -r query; do

    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES=$(./clickhouse local --path . --time --format Null --filesystem_cache_name cache --input_format_parquet_use_native_reader_v3 1 --progress 0 --query="$query" 2>&1)
        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "

        echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done
./clickhouse local --path . --query="DROP TABLE hits"

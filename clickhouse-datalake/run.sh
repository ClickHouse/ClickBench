#!/bin/bash

TRIES=3
QUERY_NUM=1

./clickhouse local --path . --query="$(cat create.sql)"
cat queries.sql | while read -r query; do

    echo -n "["
    for i in $(seq 1 $TRIES); do
        OUT=$(./clickhouse local --path . --time --format Null --filesystem_cache_name cache --query="$query" 2>&1) # (*)
        CH_EXIT=$?
        RES=$(printf '%s\n' "$OUT" | tail -n1)

        [[ "$CH_EXIT" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
        [[ "$CH_EXIT" == "139" ]] && echo "SEGFAULT: q=${QUERY_NUM} try=${i} ${RES}" >&2

        echo "${QUERY_NUM},${i},${RES},${CH_EXIT}" >> result.csv
    done
    echo "],"

    # (*) --format=Null is client-side formatting. The query result is still sent back to the client.

    QUERY_NUM=$((QUERY_NUM + 1))
done
./clickhouse local --path . --query="DROP TABLE hits"

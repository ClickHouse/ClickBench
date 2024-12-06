#!/bin/bash

TRIES=3
QUERY_NUM=1
TOTAL_LINES=$(wc -l < queries.sql)
cat queries.sql | while read query; do
    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES=$(yt clickhouse execute "$query" --alias $CHYT_ALIAS --proxy $YT_PROXY --format JSON |  jq .statistics.elapsed 2>&1)
        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
    done
    if [[ $QUERY_NUM == $TOTAL_LINES ]]
   	then echo "]"
    else
	echo "],"
    fi
    QUERY_NUM=$((QUERY_NUM + 1))
done

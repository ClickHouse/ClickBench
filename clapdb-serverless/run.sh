#!/bin/bash

TRIES=3

QUERY_NUM=1
echo "query_num,try,execution_time" >result.csv
cat queries.sql | while read query; do
    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES=$(clapctl -n ${deployment} sql -v -s "$query /*dispatch.segment_number=6; groupby_partition_count=36*/" | grep 'x-process-time' | awk '{print $3}')
        if [[ -n "$RES" ]]; then
            echo -n "${RES}"
            echo "${QUERY_NUM},${i},${RES}" >>result.csv
        else
            echo -n "null"
            echo "${QUERY_NUM},${i},null" >>result.csv
        fi
        [[ "$i" != $TRIES ]] && echo -n ", "
    done
    echo "],"
    QUERY_NUM=$((QUERY_NUM + 1))
done

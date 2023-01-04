#!/bin/bash

export KI_PWD=admin

TRIES=3
QUERY_NUM=1
cat queries.sql | while read query; do
    [ -z "$HOST" ] && sync
    [ -z "$HOST" ] && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    echo -n "["
    for i in $(seq 1 $TRIES); do
	RES=$(./kisql --host localhost --user admin --sql "$query" 2>&1 | rg 'Query Execution Time' | awk '{print $(NF-1)}' ||:)

        [[ "$?" == "0" && "$RES" != "" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "

        echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done

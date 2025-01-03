#!/bin/bash

TRIES=3
QUERY_NUM=1
cat queries.sql | while read -r query; do
    clickhouse-client --query "SYSTEM DROP FILESYSTEM CACHE"

    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES=$(clickhouse-client --host "${FQDN:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} --time --format=Null --query="$query" --progress 0 2>&1 ||:)
        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "

        echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done

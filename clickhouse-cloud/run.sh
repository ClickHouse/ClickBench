#!/bin/bash

TRIES=3
QUERY_NUM=1
cat queries.sql | while read -r query; do
    echo -n "["
    for i in $(seq 1 $TRIES); do
        clickhouse-client --host "${FQDN:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} --time --format=Null --query="$query" --progress 0 2>&1 |
            grep -o -P '^\d+\.\d+$' | tr -d '\n' || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done

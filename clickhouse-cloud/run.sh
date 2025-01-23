#!/bin/bash

TRIES=3
QUERY_NUM=1
cat queries.sql | while read -r query; do
    echo -n "["
    for i in $(seq 1 $TRIES); do
        if [[ "$i" == 1 ]]
        then
            CACHE_PARAMS='--enable_filesystem_cache 0'
        fi

        (clickhouse-client --host "${FQDN:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} ${CACHE_PARAMS} --time --format=Null --query="$query" --progress 0 2>&1 |
            grep -o -P '^\d+\.\d+$' || echo -n "null") | tr -d '\n'

        [[ "$i" != $TRIES ]] && echo -n ", "
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done

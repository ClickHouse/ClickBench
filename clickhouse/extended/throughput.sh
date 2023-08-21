#!/bin/bash

FQDN="$1"
PASSWORD="$2"

TRIES=3
QUERY_NUM=1
cat queries_throughput.sql | while read query; do
    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES=$(clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --time --format=Null --query="$query" 2>&1 ||:)
        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "

        echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done

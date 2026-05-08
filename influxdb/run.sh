#!/bin/bash

TRIES=3
URL="http://localhost:8181/api/v3/query_sql"

set -f
while IFS= read -r query; do
    [ -z "$query" ] && continue
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    body=$(jq -n --arg q "$query" '{db: "hits", q: $q, format: "json"}')

    echo -n "["
    for i in $(seq 1 $TRIES); do
        t1=$(date +%s%N)
        # `-s` (silent) without `-S` so transient curl errors like the
        # "transfer closed" message that DataFusion emits when a query OOMs
        # don't pollute the captured benchmark log; the non-zero exit code
        # is enough for us to record a `null` below.
        curl -s --fail --max-time 600 -H 'Content-Type: application/json' \
            -X POST "$URL" -d "$body" > /dev/null 2>&1
        rc=$?
        t2=$(date +%s%N)
        if [ "$rc" = "0" ]; then
            awk "BEGIN { printf \"%.3f\", ($t2 - $t1) / 1000000000 }"
        else
            echo -n "null"
        fi
        [ "$i" != "$TRIES" ] && echo -n ", "
    done
    echo "],"
done < queries.sql

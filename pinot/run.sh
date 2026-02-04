#!/bin/bash

TRIES=3
cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    echo -n "["
    for i in $(seq 1 $TRIES); do
        echo "{\"sql\":\"$query  option(timeoutMs=300000)\"}"| tr -d ';' > query.json
        OUT=$(curl -s -XPOST -H'Content-Type: application/json' http://localhost:8000/query/sql/ -d @query.json | jq 'if .exceptions == [] then .timeUsedMs/1000 else "-" end' 2>&1)
        CH_EXIT=$?
        RES=$(printf '%s\n' "$OUT" | tail -n1)
        [[ "$CH_EXIT" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
        [[ "$CH_EXIT" == "139" ]] && echo "SEGFAULT: try=${i} ${RES}" >&2
    done
    echo "],"
done

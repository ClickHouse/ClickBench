#!/bin/bash

# Determine which set of files to use depending on the type of run
if [ "$1" != "" ] && [ "$1" != "tuned" ] && [ "$1" != "tuned-memory" ]; then
    echo "Error: command line argument must be one of {'', 'tuned', 'tuned-memory'}"
    exit 1
else if [ ! -z "$1" ]; then
    SUFFIX="-$1"
fi
fi

TRIES=3
QUERY_NUM=1
cat queries"$SUFFIX".sql | while read -r query; do
    [ -z "$FQDN" ] && sync
    [ -z "$FQDN" ] && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    echo -n "["
    for i in $(seq 1 $TRIES); do
        OUT=$(clickhouse-client --host "${FQDN:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} --time --format=Null --query="$query" --progress 0 2>&1)
        CH_EXIT=$?
        RES=$(printf '%s\n' "$OUT" | tail -n1) # (*)

        [[ "$CH_EXIT" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
        [[ "$CH_EXIT" == "139" ]] && echo "SEGFAULT: q=${QUERY_NUM} try=${i} ${RES}" >&2

        echo "${QUERY_NUM},${i},${RES},${CH_EXIT}" >> result.csv
    done
    echo "],"

    # (*) --format=Null is client-side formatting. The query result is still sent back to the client.

    QUERY_NUM=$((QUERY_NUM + 1))
done

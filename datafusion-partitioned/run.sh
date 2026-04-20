#!/bin/bash

TRIES=3
QUERY_NUM=1
SETUP_STATEMENTS=$(grep -o ';' create.sql | wc -l | tr -d '[:space:]')
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

echo $1
while IFS= read -r query || [ -n "$query" ]; do
    [ -z "$query" ] && continue

    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    QUERY_FILE="${TMP_DIR}/query-${QUERY_NUM}.sql"
    cp create.sql "${QUERY_FILE}"
    printf '\n' >> "${QUERY_FILE}"
    for i in $(seq 1 $TRIES); do
        printf '%s\n\n' "$query" >> "${QUERY_FILE}"
    done

    ALL_ELAPSED_VALUES=()
    while IFS= read -r res; do
        ALL_ELAPSED_VALUES[${#ALL_ELAPSED_VALUES[@]}]="$res"
    done < <(
        datafusion-cli -f "${QUERY_FILE}" 2>&1 |
        awk '/Elapsed/ { print $2 }'
    )

    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES="${ALL_ELAPSED_VALUES[$((SETUP_STATEMENTS + i - 1))]}"
        [[ $RES != "" ]] && \
            echo -n "$RES" || \
            echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
        echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done < queries.sql

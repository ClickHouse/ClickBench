#!/bin/bash

#set -x
TRIES=3
QUERY_NUM=1

set -o allexport
source ../.env
set +o allexport


timestamp=$(date +"%Y%m%d-%H%M%S")

# rename
if [ -f "result.csv" ]; then
    mv result.csv "result_$timestamp.csv"
    echo "Old file renamed: result_$timestamp.csv"
fi
# Clear result file first
> result.csv

cat queries.sql | while read -r query; do
    # Build the entire line first
    line="["

    for i in $(seq 1 $TRIES); do
        result=$(clickhouse client \
            --config-file=$PATH2XML\
            --host "${FQDN:=localhost}" \
            --port 9440 \
            --user "${USER:=}"  \
            --password "${PASSWORD:=}" \
            ${PASSWORD:+--secure} \
            --time \
            --format=Null \
            --query="$query" \
            --progress 0 \
            ${EXTRA_SETTINGS} 2>&1 | \
            ggrep -o -P '^\d+\.\d+$' | head -1 || echo "null")

        line="${line}${result}"
        [[ "$i" != $TRIES ]] && line="${line},"
    done

    line="${line}],"

    # Output to both screen and file
    echo "$line" | tee -a result.csv

    QUERY_NUM=$((QUERY_NUM + 1))
done
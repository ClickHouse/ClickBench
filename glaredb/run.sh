#!/usr/bin/env bash

set -eu
set -o pipefail

case "$1" in
    single)
        create_sql_file="create_single.sql"
        ;;
    partitioned)
        create_sql_file="create_partitioned.sql"
        ;;
    *)
        echo "Invalid argument to 'run.sh', expected 'single' or 'partitioned'"
        exit 1
        ;;
esac

TRIES=3
QUERY_NUM=0

echo "[" > results.json
echo "query_num,iteration,duration" > results.csv

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    echo "${QUERY_NUM}: ${query}"

    [ "${QUERY_NUM}" != 0 ] && echo "," >> results.json
    echo -n "    [" >> results.json

    for i in $(seq 1 $TRIES); do
        output=$(./glaredb --init "${create_sql_file}" -c ".timer on" -c "${query}")
        duration=$(awk -F': ' '/^Execution duration/ { printf "%.3f\n", $2 }' <<< "$output")

        echo "$output"

        if [ -z "${duration}" ]; then
           echo "Query failed"
           exit 1
        fi

        # JSON results
        echo -n "${duration}" >> results.json
        [ "${i}" != "${TRIES}" ] && echo -n "," >> results.json

        # CSV results
        echo "${QUERY_NUM},${i},${duration}" >> results.csv
    done

    echo -n "]" >> results.json

    QUERY_NUM=$((QUERY_NUM + 1))
done

echo "" >> results.csv
echo "" >> results.json
echo "]" >> results.json

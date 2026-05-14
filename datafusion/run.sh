#!/bin/bash

TRIES=3
QUERY_NUM=1
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

echo $1
while read -r query; do
    [ -z "$query" ] && continue

    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    QUERY_FILE="${TMP_DIR}/query-${QUERY_NUM}.sql"
    MARKER="clickbench_query_${QUERY_NUM}_start"
    printf "SELECT '${MARKER}';\n\n" > "${QUERY_FILE}"
    for i in $(seq 1 $TRIES); do
        printf '%s\n\n' "$query" >> "${QUERY_FILE}"
    done

    # Keep all tries in one process so DataFusion process-local caches stay hot.
    # Use a marker query to ignore setup timings from create.sql.
    ELAPSED_FILE="${TMP_DIR}/elapsed-${QUERY_NUM}.txt"
    OUTPUT_FILE="${TMP_DIR}/output-${QUERY_NUM}.txt"
    datafusion-cli -f create.sql "${QUERY_FILE}" > "${OUTPUT_FILE}" 2>&1
    awk -v marker="$MARKER" '
        index($0, marker) { seen = 1 }
        seen && /Elapsed/ {
            if (!skipped_marker_elapsed) {
                skipped_marker_elapsed = 1
                next
            }
            print $2
        }
    ' "${OUTPUT_FILE}" > "${ELAPSED_FILE}"
    if [ "$(wc -l < "${ELAPSED_FILE}")" -lt "$TRIES" ]; then
        grep -v "Elapsed" "${OUTPUT_FILE}" >&2
    fi

    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES=$(awk -v line="$i" 'NR == line { print; exit }' "${ELAPSED_FILE}")
        [[ $RES != "" ]] && \
            echo -n "$RES" || \
            echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
        echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done < queries.sql

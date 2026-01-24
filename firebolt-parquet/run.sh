#!/bin/bash

# Disable the result and subresult caches.
QUERY_PARAMS="enable_result_cache=false&enable_subresult_cache=false&output_format=JSON_Compact"

cat queries.sql | while read -r query; do
    # Firebolt is a database with local on-disk storage: drop the page cache before the first run of each query.
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    # Run the query three times.
    # Extract the elapsed time from the response's statistics.
    ELAPSED=$(curl -sS "http://localhost:3473/?database=clickbench&${QUERY_PARAMS}" --data-binary "$query" | jq '.statistics.elapsed')
    echo -n "[${ELAPSED}"
    ELAPSED=$(curl -sS "http://localhost:3473/?database=clickbench&${QUERY_PARAMS}" --data-binary "$query" | jq '.statistics.elapsed')
    echo -n ",${ELAPSED}"
    ELAPSED=$(curl -sS "http://localhost:3473/?database=clickbench&${QUERY_PARAMS}" --data-binary "$query" | jq '.statistics.elapsed')
    echo ",${ELAPSED}],"
done

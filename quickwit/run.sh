#!/bin/bash

TRIES=3
SEARCH_URL="http://localhost:7280/api/v1/_elastic/hits/_search"

while IFS= read -r QUERY; do
    if [ "$QUERY" != "null" ]; then
        # Restart Quickwit before each query to clear all in-process caches
        # (fast_field_cache, split_footer_cache). Result-style caches
        # (partial_request_cache, predicate_cache) are already disabled in
        # node-config.yaml. Then drop the OS page cache. This makes the first
        # run cold; runs 2 and 3 may benefit from caches re-warmed by run 1.
        sudo docker restart qw >/dev/null
        until curl -sS -f http://localhost:7280/api/v1/version >/dev/null 2>&1; do sleep 1; done
        sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    fi

    echo -n "["

    for i in $(seq 1 $TRIES); do
        if [ "$QUERY" = "null" ]; then
            # Query is not expressible in Quickwit (e.g. text-field sort,
            # scripts, REGEXP_REPLACE).
            echo -n "null"
        else
            START=$(date +%s.%N)
            QW_RSP=$(curl -s -X POST "$SEARCH_URL" -H 'Content-Type: application/json' -d "$QUERY")
            END=$(date +%s.%N)

            # Quickwit returns "took" in milliseconds (engine-internal latency).
            QW_TIME=$(echo "$QW_RSP" | jq -r 'if has("error") or has("status") then "null" else (.took | tostring) end')

            if [ "$QW_TIME" = "null" ] || [ -z "$QW_TIME" ]; then
                echo -n "null"
            else
                printf "%.4f" "$(echo "scale=4; $QW_TIME / 1000" | bc)"
            fi
        fi

        [ "$i" != "$TRIES" ] && echo -n ", "
    done

    echo "],"
done < queries.json

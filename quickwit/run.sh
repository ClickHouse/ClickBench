#!/bin/bash

TRIES=3
SEARCH_URL="http://localhost:7280/api/v1/_elastic/hits/_search"

while IFS= read -r QUERY; do
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    echo -n "["

    for i in $(seq 1 $TRIES); do
        if [ "$QUERY" = "null" ]; then
            # Query is not expressible in Quickwit (e.g. cardinality, scripts, regex_replace).
            echo -n "null"
        else
            START=$(date +%s.%N)
            QW_RSP=$(curl -s -X POST "$SEARCH_URL" -H 'Content-Type: application/json' -d "$QUERY")
            END=$(date +%s.%N)

            # Quickwit returns "took" in milliseconds (the engine-internal latency).
            QW_TIME=$(echo "$QW_RSP" | jq -r 'if has("error") or has("status") then "null" else (.took | tostring) end')

            if [ "$QW_TIME" = "null" ] || [ -z "$QW_TIME" ]; then
                echo -n "null"
            else
                # Convert ms -> seconds with 4-decimal precision.
                printf "%.4f" "$(echo "scale=4; $QW_TIME / 1000" | bc)"
            fi
        fi

        [ "$i" != "$TRIES" ] && echo -n ", "
    done

    echo "],"
done < queries.json

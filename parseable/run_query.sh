#!/bin/bash

echo "Running queries..."
TRIES=3
QUERY_NUM=1
rm -f result.csv

# Get current date in YYYY-MM-DD format
CURRENT_DATE=$(date +%Y-%m-%d)
START_TIME="${CURRENT_DATE}T00:00:00.000Z"
END_TIME="${CURRENT_DATE}T23:59:00.000Z"

cat 'queries.sql' | while read -r QUERY; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    echo "$QUERY" > /tmp/query.sql
    echo "Query $QUERY_NUM: $QUERY"
    QUERY=$(echo "$QUERY" | sed 's/"/\\"/g')
    # Create array to store results for this query
    RESULTS=()

    for i in $(seq 1 $TRIES); do
        echo "Iteration $i:"
JSON=$(printf '{"query":"%s","startTime":"%s","endTime":"%s"}' "$QUERY" "$START_TIME" "$END_TIME")

        start_time=$(date +%s.%N)

        # Execute the query and print the response to terminal
        curl -s -H "Content-Type: application/json" -k -XPOST -u "admin:admin" "http://localhost:8000/api/v1/query" --data "${JSON}" > /dev/null
        end_time=$(date +%s.%N)

        # Calculate elapsed time in seconds with millisecond precision
        elapsed_time=$(echo "$end_time - $start_time" | bc)
        # Convert to desired format
        RES=$(printf "%.9f" $elapsed_time)

        # Store result in array
        RESULTS+=("$RES")

        echo "Time: $RES seconds"
        echo "----------------------------------------"
    done

    # Output results to CSV with tab separation
    echo -e "${RESULTS[0]} ${RESULTS[1]} ${RESULTS[2]}" >> result.csv

    echo "Query $QUERY_NUM completed. [${RESULTS[0]}, ${RESULTS[1]}, ${RESULTS[2]}]"
    echo "========================================"
    QUERY_NUM=$((QUERY_NUM + 1))
done

echo "Benchmark completed. Results saved to result.csv"
#!/bin/bash
# Arc ClickBench Benchmark Runner - TRUE COLD RUNS
# Restarts Arc service and clears OS cache before EACH QUERY (not each run)
# Pattern: restart -> run query 3 times -> next query

TRIES=3
ARC_URL="${ARC_URL:-http://localhost:8000}"
ARC_API_KEY="${ARC_API_KEY:-$(cat arc_token.txt 2>/dev/null)}"

echo "Running benchmark with TRUE COLD RUNS (restart + cache clear before each query)" >&2
echo "API endpoint: $ARC_URL" >&2

# Function to restart Arc and clear caches
restart_arc() {
    # Stop Arc
    sudo systemctl stop arc

    # Clear OS page cache
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    # Start Arc
    sudo systemctl start arc

    # Wait for Arc to be ready
    for i in {1..30}; do
        if curl -sf "$ARC_URL/health" > /dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    echo "Error: Arc failed to restart" >&2
    return 1
}

# Read queries line by line
cat queries.sql | while read -r query; do
    # Skip empty lines and comments
    [[ -z "$query" || "$query" =~ ^-- ]] && continue

    # TRUE COLD RUN: Restart Arc and clear OS cache ONCE per query
    restart_arc

    echo "$query" >&2

    # Run the query 3 times (first is cold, 2-3 benefit from warm DB caches)
    for i in $(seq 1 $TRIES); do
        # Mark the log position before query
        LOG_MARKER=$(date -u +"%Y-%m-%dT%H:%M:%S")

        # Execute query
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "$ARC_URL/api/v1/query" \
            -H "x-api-key: $ARC_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"sql\": \"$query\"}" \
            --max-time 300 2>/dev/null)

        if [ "$HTTP_CODE" = "200" ]; then
            # Extract execution_time_ms from Arc logs
            # Log format: 2025-11-28T14:20:44Z INF ... execution_time_ms=97 ...
            sleep 0.1  # Small delay to ensure log is written
            EXEC_TIME_MS=$(sudo journalctl -u arc --since="$LOG_MARKER" --no-pager 2>/dev/null | \
                grep -oP 'execution_time_ms=\K[0-9]+' | tail -1)

            if [ -n "$EXEC_TIME_MS" ]; then
                # Convert ms to seconds with 4 decimal places
                EXEC_TIME_SEC=$(echo "scale=4; $EXEC_TIME_MS / 1000" | bc)
                printf "%.4f\n" "$EXEC_TIME_SEC"
            else
                echo "null"
                echo "Warning: Could not extract execution_time_ms from logs" >&2
            fi
        else
            echo "null"
            if [ "$i" -eq 1 ]; then
                echo "Query failed (HTTP $HTTP_CODE): ${query:0:50}..." >&2
            fi
        fi
    done
done

echo "Benchmark complete!" >&2

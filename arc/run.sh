#!/bin/bash
# Arc ClickBench Benchmark Runner - TRUE COLD RUNS
# Restarts Arc service and clears OS cache before EACH QUERY (not each run)
# Pattern: restart -> run query 3 times -> next query

TRIES=3
ARC_URL="${ARC_URL:-http://localhost:8000}"
ARC_API_KEY="${ARC_API_KEY:-$(cat arc_token.txt 2>/dev/null)}"

echo "Running benchmark with TRUE COLD RUNS (restart + cache clear before each query)" >&2
echo "API endpoint: $ARC_URL" >&2

# Build auth header if token exists
AUTH_HEADER=""
if [ -n "$ARC_API_KEY" ]; then
    AUTH_HEADER="-H x-api-key: $ARC_API_KEY"
    echo "API key: ${ARC_API_KEY:0:20}..." >&2
else
    echo "No API key (auth disabled)" >&2
fi

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
            sleep 0.2  # Extra delay to ensure server is fully ready
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
        # Build JSON payload properly using printf to escape the query
        JSON_PAYLOAD=$(printf '{"sql": %s}' "$(echo "$query" | jq -Rs .)")

        # Execute query (with or without auth header)
        if [ -n "$ARC_API_KEY" ]; then
            RESPONSE=$(curl -s -w "\n%{http_code}" \
                -X POST "$ARC_URL/api/v1/query" \
                -H "x-api-key: $ARC_API_KEY" \
                -H "Content-Type: application/json" \
                -d "$JSON_PAYLOAD" \
                --max-time 300 2>/dev/null)
        else
            RESPONSE=$(curl -s -w "\n%{http_code}" \
                -X POST "$ARC_URL/api/v1/query" \
                -H "Content-Type: application/json" \
                -d "$JSON_PAYLOAD" \
                --max-time 300 2>/dev/null)
        fi

        HTTP_CODE=$(echo "$RESPONSE" | tail -1)
        BODY=$(echo "$RESPONSE" | head -n -1)

        if [ "$HTTP_CODE" = "200" ]; then
            # Extract execution_time_ms from JSON response
            EXEC_TIME_MS=$(echo "$BODY" | jq -r '.execution_time_ms // empty')
            if [ -n "$EXEC_TIME_MS" ]; then
                # Convert ms to seconds with 4 decimal places
                EXEC_TIME_SEC=$(echo "scale=4; $EXEC_TIME_MS / 1000" | bc)
                printf "%.4f\n" "$EXEC_TIME_SEC"
            else
                echo "null"
                echo "Warning: execution_time_ms not found in response" >&2
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

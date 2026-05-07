#!/bin/bash

# Source our env vars
. util.sh

TRIES=3
TEMP_SQL_FILE="/tmp/benchmark_queries_$$.sql"

# Ensure server is stopped on script exit
trap stop_gizmosql EXIT

# Read queries from file
mapfile -t queries < queries.sql

echo "Running benchmark with ${#queries[@]} queries, ${TRIES} tries each..."

for query in "${queries[@]}"; do
    > "${TEMP_SQL_FILE}"

    # Clear Linux memory caches to ensure fair benchmark comparisons
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    # Start the GizmoSQL server
    start_gizmosql

    # Enable timer and discard result rows (we only care about Run Time)
    echo ".timer on" >> "${TEMP_SQL_FILE}"
    echo ".mode trash" >> "${TEMP_SQL_FILE}"

    # Add a comment to identify the query in the output
    echo "-- Query: ${query}" >> "${TEMP_SQL_FILE}"

    # Repeat each query TRIES times
    for i in $(seq 1 ${TRIES}); do
        echo "${query}" >> "${TEMP_SQL_FILE}"
    done

    # Execute the query script (timer output goes to stderr; merge to stdout)
    gizmosql_client --file "${TEMP_SQL_FILE}" 2>&1

    # Stop the server before next query
    stop_gizmosql
done

# Clean up
rm -f "${TEMP_SQL_FILE}"

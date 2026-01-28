#!/bin/bash

# Source our env vars
. util.sh

TRIES=3
TEMP_SQL_FILE="/tmp/benchmark_queries_$$.sql"

# Ensure server is stopped on script exit
trap stop_gizmosql EXIT

echo "Clear Linux memory caches to ensure fair benchmark comparisons"
sync
echo 3 | tee /proc/sys/vm/drop_caches > /dev/null

# Read queries from file
mapfile -t queries < queries.sql

echo "Running benchmark with ${#queries[@]} queries, ${TRIES} tries each..."

for query in "${queries[@]}"; do
    > "${TEMP_SQL_FILE}"

    # Start the GizmoSQL server
    start_gizmosql

    # Add a comment to identify the query in the output
    echo "-- Query: ${query}" >> "${TEMP_SQL_FILE}"

    # Repeat each query TRIES times
    for i in $(seq 1 ${TRIES}); do
        echo "${query}" >> "${TEMP_SQL_FILE}"
    done

    # Execute the query script
    gizmosqlline \
        -u ${GIZMOSQL_SERVER_URI} \
        -n ${GIZMOSQL_USERNAME} \
        -p ${GIZMOSQL_PASSWORD} \
        -f "${TEMP_SQL_FILE}"

    # Stop the server before next query
    stop_gizmosql
done

# Clean up
rm -f "${TEMP_SQL_FILE}"

#!/bin/bash

TRIES=3
TEMP_SQL_FILE="/tmp/benchmark_queries_$$.sql"

# Read queries from file
mapfile -t queries < queries.sql

# Create the combined SQL script with each query repeated TRIES times
> "${TEMP_SQL_FILE}"

for query in "${queries[@]}"; do
    # Add a comment to identify the query in the output
    echo "-- Query: ${query}" >> "${TEMP_SQL_FILE}"

    # Repeat each query TRIES times
    for i in $(seq 1 ${TRIES}); do
        echo "${query}" >> "${TEMP_SQL_FILE}"
    done
done

# Execute all queries in one session (so authentication overhead is minimized)
echo "Running benchmark with $(wc -l < queries.sql) queries, ${TRIES} tries each..."

gizmosqlline \
  -u 'jdbc:arrow-flight-sql://localhost:31337?useEncryption=true&disableCertificateVerification=true' \
  -n clickbench \
  -p clickbench \
  -f "${TEMP_SQL_FILE}"

# Clean up
rm -f "${TEMP_SQL_FILE}"

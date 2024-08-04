#!/bin/bash

# disable cache manager to prevent auto-loading of files
$SUPERUSERCONNCMD -c 'ALTER SYSTEM SET crunchy_query_engine.enable_cache_manager TO off;'
$SUPERUSERCONNCMD -c 'SELECT pg_reload_conf();'
$SUPERUSERCONNCMD -c 'SHOW crunchy_query_engine.enable_cache_manager;'

# make sure there are no leftover files locally available
$APPCONNCMD -c 'select crunchy_file_cache.remove(path) FROM crunchy_file_cache.list();'

# create the table
$APPCONNCMD -f create.sql

# Initialize the results array
declare -A results

# Function to run queries and store results
run_queries() {
    local run_number=$1
    local query_index=0

    while read -r query; do
        time_ms=$($APPCONNCMD -c '\timing' -c "$query" | grep 'Time' | awk '{print $2}')
        time_sec=$(echo "scale=4; $time_ms / 1000" | bc)
        time_sec=$(printf "%.4f" $time_sec)  # Ensure leading zero

        # Append the result to the appropriate query's results array
        if [ $run_number -eq 0 ]; then
            results[$query_index]="$time_sec"
        else
            results[$query_index]+=",$time_sec"
        fi
        query_index=$((query_index + 1))
    done < queries.sql
}

# Run queries for the first time without file downloaded locally, add to results
run_queries 0

# Enable loading the file locally
$SUPERUSERCONNCMD -c 'ALTER SYSTEM SET crunchy_query_engine.enable_cache_manager TO on;'
$SUPERUSERCONNCMD -c 'SELECT pg_reload_conf();'
$SUPERUSERCONNCMD -c 'SHOW crunchy_query_engine.enable_cache_manager;'

# Synchronously load the file to the local machine
$APPCONNCMD -c "SELECT * FROM crunchy_file_cache.add('s3://clickhouse-public-datasets/hits_compatible/hits.parquet');"

# Run queries for the second and third times with file locally available
run_queries 1
run_queries 2

# Format the results
echo '"result": ['
for ((i = 0; i < ${#results[@]}; i++)); do
    echo "[${results[$i]}],"
done | sed '$ s/,$//'
echo "]"

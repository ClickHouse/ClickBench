#!/bin/bash

TRIES=3

echo '"result": ['

cat queries.sql | while read query; do
    times=()
    for i in $(seq 1 $TRIES); do
        time_ms=$($CONNCMD -c '\timing' -c "$query" | grep 'Time' | awk '{print $2}')
        time_sec=$(echo "scale=4; $time_ms / 1000" | bc)
        time_sec=$(printf "%.4f" $time_sec)  # Ensure leading zero
        times+=($time_sec)
    done
    echo "[${times[0]},${times[1]},${times[2]}],"
done | sed '$ s/,$//'

echo "]"


#!/bin/bash

# Check if an argument is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 [single|partitioned]"
    exit 1
fi

# Set the SQL file based on the argument
if [ "$1" == "single" ] || [ "$1" == "partitioned" ]; then
    FLAVOR=$1
    echo "Running benchmark for $FLAVOR"
else
    echo "Invalid argument. Please use 'single' or 'partitioned'."
    exit 1
fi

# clear results file
touch results.csv
> results.csv 

TRIES=3
OS=$(uname -s)

for query_num in $(seq 0 42); do
    sync

    if [ "$OS" = "Linux" ]; then
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    elif [ "$OS" = "Darwin" ]; then
        sudo purge
    fi

    echo -n "["
    for i in $(seq 1 $TRIES); do
        # Parse query results out of the JSON output, which reports the time in ns
        RES=$(RUST_LOG=off query_bench clickbench -i 1 --flavor $FLAVOR --targets datafusion:vortex --display-format gh-json --queries-file ./queries.sql -q $query_num --hide-progress-bar | jq ".value / 1000000000")

        [[ $RES != "" ]] && \
            echo -n "$RES" || \
            echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
        echo "${query_num},${i},${RES}" >> results.csv
    done
    echo "],"
done

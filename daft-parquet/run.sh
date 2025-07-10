#!/bin/bash

mode=${1}

TRIES=3
QUERY_COUNT=43

declare -a results=()
for ((i=0; i<QUERY_COUNT; i++)); do
    nulls=$(printf 'null%.0s' $(seq 1 $TRIES))
    results[i]="[${nulls// /,}]"
done

mkdir -p results

for ((q=1; q<=QUERY_COUNT; q++)); do
    echo "Processing query $q..."

    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    output=$(python3 query.py $q $mode 2>&1)
    IFS=',' read -r t1 t2 t3 <<< "$(echo "$output" | tail -1)"

    results[$((q-1))]="[${t1:-null},${t2:-null},${t3:-null}]"
done

IFS=, printf '%s,\n' "${results[@]}" | sed '$s/,$//'

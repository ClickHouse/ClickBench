#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    echo "$query";
    cli_params=()
    cli_params+=("-c")
    cli_params+=(".timer on")
    for i in $(seq 1 $TRIES); do
      cli_params+=("-c")
      cli_params+=("${query}")
    done;
    echo "${cli_params[@]}"
    duckdb hits.db "${cli_params[@]}"
done;

#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    echo "$query";
    cli_params=()
    cli_params+=(":memory:")
    cli_params+=("-c")
    cli_params+=("SET preserve_insertion_order = false;")
    cli_params+=("-c")
    cli_params+=(".timer on")
    cli_params+=("-c")
    cli_params+=(".read create.sql")
    cli_params+=("-c")
    cli_params+=(".read load.sql")
    for i in $(seq 1 $TRIES); do
      cli_params+=("-c")
      cli_params+=("${query}")
    done;
    echo "${cli_params[@]}"
    duckdb "${cli_params[@]}"
done;

#!/bin/bash

TRIES=3
GPU_CACHING_SIZE='40 GB'
GPU_PROCESSING_SIZE='40 GB'

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    echo "$query";
    cli_params=()
    cli_params+=("-c")
    cli_params+=(".timer on")
    cli_params+=("-c")
    cli_params+=("call gpu_buffer_init(\"${GPU_CACHING_SIZE}\", \"${GPU_PROCESSING_SIZE}\");")
    for i in $(seq 1 $TRIES); do
      cli_params+=("-c")
      cli_params+=("call gpu_processing(\"${query}\");")
    done;
    echo "${cli_params[@]}"
    duckdb hits.db "${cli_params[@]}"
done;

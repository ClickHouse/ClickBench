#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    sudo docker exec memsql-ciab memsql -vvv -p"${ROOT_PASSWORD}" --database=test -e "USE test; ${query}"

    # to get the most accurate 'hot' query results, wait for async compilations to finish to ensure we have a compiled plan
    while [[ $( sudo docker exec memsql-ciab memsql -vvv -p"${ROOT_PASSWORD}" --database=test -e 'select sum(variable_value) v from information_schema.mv_global_status where variable_name = "Inflight_async_compilations" having v != 0') ]]; do
        sleep 1
    done

    for i in $(seq 2 $TRIES); do
        sudo docker exec memsql-ciab memsql -vvv -p"${ROOT_PASSWORD}" --database=test -e "USE test; ${query}"
    done;
done;

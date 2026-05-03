#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    # Restart the container so the columnstore blob cache and plan cache do
    # not survive into the next "cold" run. SingleStore keeps decoded segment
    # data in a process-internal blob cache that drop_caches cannot clear and
    # exposes no public flush API.
    sudo docker restart memsql-ciab
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    until sudo docker exec memsql-ciab memsql -p"${ROOT_PASSWORD}" --database=test -e 'select 1' >/dev/null 2>&1; do
        sleep 1
    done

    sudo docker exec memsql-ciab memsql -vvv -p"${ROOT_PASSWORD}" --database=test -e "USE test; ${query}"

    # to get the most accurate 'hot' query results, wait for async compilations to finish to ensure we have a compiled plan
    while [[ $( sudo docker exec memsql-ciab memsql -vvv -p"${ROOT_PASSWORD}" --database=test -e 'select sum(variable_value) v from information_schema.mv_global_status where variable_name = "Inflight_async_compilations" having v != 0') ]]; do
        sleep 1
    done

    for i in $(seq 2 $TRIES); do
        sudo docker exec memsql-ciab memsql -vvv -p"${ROOT_PASSWORD}" --database=test -e "USE test; ${query}"
    done;
done;

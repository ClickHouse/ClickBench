#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    docker restart $(docker ps -a -q)

    # wait for the server quietly so retry-loop messages don't pollute log.txt
    # (the awk filter in benchmark.sh treats any `psql: error` line as a failed query)
    until pg_isready -h localhost --dbname postgres -U postgres > /dev/null 2>&1; do sleep 1; done
    until PGPASSWORD=test psql -h localhost -U postgres -c "SELECT 'Ok';" > /dev/null 2>&1; do sleep 1; done

    echo "$query";
    for i in $(seq 1 $TRIES); do
        PGPASSWORD=test psql -h localhost -U postgres -t -c '\timing' -c "$query" 2>&1 | grep -P 'Time|psql: error' | tail -n1
    done
done

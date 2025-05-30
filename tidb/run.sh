#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    for i in $(seq 1 $TRIES); do
        mysql --host 127.0.0.1 --port 4000 -u root test -vvv -e "${query}"
    done;
done;

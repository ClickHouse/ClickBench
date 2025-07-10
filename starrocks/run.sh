#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

    for i in $(seq 1 $TRIES); do
        mysql -vvv -h127.1 -P9030 -uroot hits -e "${query}"
    done
done;

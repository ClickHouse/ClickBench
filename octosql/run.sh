#!/bin/bash

max_rss=$(( $(cat /proc/meminfo | grep MemTotal | grep -o -P '\d+') * 900 ))

cat queries.sql | sed -r -e 's@hits@hits.parquet@' | while read query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    for _ in {1..3}
    do
        time prlimit --data="${max_rss}" ./octosql "${query}"
    done
done
